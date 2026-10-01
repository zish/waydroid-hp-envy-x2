/*
 * nl80211 over a raw AF_NETLINK socket.  See Nl80211.h for why there is no
 * libnl on the link line.
 */

#include "Nl80211.h"

#include <gutil_log.h>

#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>

#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace waydroid {
namespace wifi {

namespace {

/*
 * Netlink alignment.  NLMSG_ALIGN and NLA_ALIGN are in the kernel headers, but
 * spelling them out locally keeps the walkers below readable and avoids any
 * argument about which header is expected to have defined them.
 */
inline size_t align4(size_t n) { return (n + 3u) & ~static_cast<size_t>(3u); }

const size_t kNlaHdr = sizeof(struct nlattr);          /* 4 */

/*
 * Attribute walking.
 *
 * Netlink attributes are length-prefixed TLVs, and EVERY bound below is checked
 * against the remaining buffer rather than trusted from nla_len.  This parses
 * kernel output, so the input is not hostile -- but it is also the one place in
 * this daemon that walks a binary buffer whose length came from outside the
 * process, and a loop that trusts its own length field is a loop that can be
 * made to run off the end by a kernel bug as easily as by an attacker.
 */
class AttrWalker {
public:
    AttrWalker(const uint8_t* data, size_t len) : mPtr(data), mLeft(len) {}

    bool next(uint16_t& type, const uint8_t*& payload, size_t& payloadLen)
    {
        while (mLeft >= kNlaHdr) {
            struct nlattr a;
            memcpy(&a, mPtr, kNlaHdr);

            /*
             * A zero or short nla_len cannot be advanced past, so it has to end
             * the walk rather than be skipped: treating it as "try the next one"
             * is an infinite loop.
             */
            if (a.nla_len < kNlaHdr || a.nla_len > mLeft) {
                mLeft = 0;
                return false;
            }

            type       = static_cast<uint16_t>(a.nla_type & NLA_TYPE_MASK);
            payload    = mPtr + kNlaHdr;
            payloadLen = a.nla_len - kNlaHdr;

            const size_t step = align4(a.nla_len);
            if (step >= mLeft) {
                mPtr += mLeft;
                mLeft = 0;
            } else {
                mPtr  += step;
                mLeft -= step;
            }
            return true;
        }
        return false;
    }

private:
    const uint8_t* mPtr;
    size_t         mLeft;
};

/*
 * Fixed-width readers.  Each one refuses a payload that is too short rather
 * than reading what happens to be next in the buffer; a missing attribute and a
 * malformed one are both "the kernel did not tell us", which every caller here
 * already has a fallback for.
 */
bool readU8(const uint8_t* p, size_t n, uint8_t& out)
{
    if (n < 1) return false;
    out = p[0];
    return true;
}

bool readU16(const uint8_t* p, size_t n, uint16_t& out)
{
    if (n < 2) return false;
    memcpy(&out, p, 2);
    return true;
}

bool readU32(const uint8_t* p, size_t n, uint32_t& out)
{
    if (n < 4) return false;
    memcpy(&out, p, 4);
    return true;
}

/*
 * Count spatial streams in an HT MCS set.
 *
 * The 16-byte HT MCS set's first four bytes are the supported single-MCS bitmap
 * for streams 1 through 4, one byte each.  A stream whose byte is zero is not
 * supported, and support is contiguous from stream 1, so the count of non-zero
 * leading bytes is the stream count.  On bigtab01's 7265 this reads 2, matching
 * `iw phy` printing "HT TX/RX MCS rate indexes supported: 0-15".
 */
int32_t htStreams(const uint8_t* mcs, size_t n)
{
    int32_t streams = 0;
    for (size_t i = 0; i < 4 && i < n; i++) {
        if (mcs[i] == 0) break;
        streams++;
    }
    return streams;
}

/*
 * Count spatial streams in a VHT MCS set.
 *
 * The first u16 of the 8-byte VHT MCS info is the rx MCS map: two bits per
 * stream for eight streams, where the value 3 means "not supported".  Same
 * contiguity argument as HT.  bigtab01 reads 2, matching `iw phy`'s
 * "1 streams: MCS 0-9 / 2 streams: MCS 0-9 / 3 streams: not supported".
 */
int32_t vhtStreams(const uint8_t* mcsInfo, size_t n)
{
    uint16_t map = 0;
    if (!readU16(mcsInfo, n, map)) {
        return 0;
    }
    int32_t streams = 0;
    for (int i = 0; i < 8; i++) {
        if (((map >> (2 * i)) & 0x3) == 3) break;
        streams++;
    }
    return streams;
}

} /* namespace */

const char*
phyName(Phy p)
{
    switch (p) {
    case Phy::Legacy: return "legacy";
    case Phy::Ht:     return "HT";
    case Phy::Vht:    return "VHT";
    case Phy::He:     return "HE";
    case Phy::Eht:    return "EHT";
    default:          return "unknown";
    }
}

Nl80211::~Nl80211()
{
    if (mFd >= 0) {
        ::close(mFd);
        mFd = -1;
    }
}

void
Nl80211::fail(const char* what, int err)
{
    mLastError = std::string(what);
    if (err) {
        mLastError += ": ";
        mLastError += strerror(err);
    }
}

bool
Nl80211::open()
{
    std::lock_guard<std::mutex> guard(mLock);

    if (mFd >= 0) {
        return true;
    }

    mFd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC);
    if (mFd < 0) {
        fail("socket(AF_NETLINK)", errno);
        return false;
    }

    struct sockaddr_nl local;
    memset(&local, 0, sizeof(local));
    local.nl_family = AF_NETLINK;
    /* nl_pid 0 asks the kernel to allocate one, which is what we want: this
     * process may also be running a hand-started instance's socket, and picking
     * our own pid as the port id collides with it. */
    if (bind(mFd, (struct sockaddr*) &local, sizeof(local)) < 0) {
        fail("bind(AF_NETLINK)", errno);
        ::close(mFd);
        mFd = -1;
        return false;
    }

    socklen_t alen = sizeof(local);
    if (getsockname(mFd, (struct sockaddr*) &local, &alen) == 0) {
        mPortId = local.nl_pid;
    }

    /*
     * A receive timeout, and the reason it is not optional: these calls are made
     * from binder transaction handlers.  A handler that blocks forever does not
     * just lose one value, it holds a binder thread from system_server's pool
     * until Android's own transaction timeout fires.  Two seconds is far longer
     * than a local netlink round trip has ever taken and still short enough that
     * Android gets its reply.
     */
    struct timeval tv;
    tv.tv_sec  = 2;
    tv.tv_usec = 0;
    if (setsockopt(mFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        /* Not fatal -- a missing timeout is a latency risk, not a wrong answer,
         * and refusing to start over it would be worse. */
        GWARN("nl80211: could not set a receive timeout: %s", strerror(errno));
    }

    if (!resolveFamily()) {
        ::close(mFd);
        mFd = -1;
        return false;
    }

    GINFO("nl80211 ready (family %u, port %u)", mFamily, mPortId);
    mLastError.clear();
    return true;
}

/*
 * Resolve the "nl80211" generic-netlink family id.
 *
 * Generic netlink family ids are assigned at module load, so there is no
 * constant to compile in -- the controller family (GENL_ID_CTRL, which IS fixed)
 * has to be asked.  Done once at open(); the id cannot change while the module
 * stays loaded, and if cfg80211 were unloaded the daemon has lost its radio
 * anyway.
 */
bool
Nl80211::resolveFamily()
{
    const char* name = "nl80211";
    const size_t nameLen = strlen(name) + 1;

    uint8_t buf[256];
    memset(buf, 0, sizeof(buf));

    struct nlmsghdr* nlh = (struct nlmsghdr*) buf;
    nlh->nlmsg_len   = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type  = GENL_ID_CTRL;
    nlh->nlmsg_flags = NLM_F_REQUEST;
    nlh->nlmsg_seq   = mSeq++;
    nlh->nlmsg_pid   = mPortId;

    struct genlmsghdr* gnlh = (struct genlmsghdr*) NLMSG_DATA(nlh);
    gnlh->cmd     = CTRL_CMD_GETFAMILY;
    gnlh->version = 1;

    struct nlattr* na = (struct nlattr*) (buf + NLMSG_ALIGN(nlh->nlmsg_len));
    na->nla_type = CTRL_ATTR_FAMILY_NAME;
    na->nla_len  = (uint16_t) (kNlaHdr + nameLen);
    memcpy((uint8_t*) na + kNlaHdr, name, nameLen);
    nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + align4(na->nla_len);

    if (send(mFd, buf, nlh->nlmsg_len, 0) < 0) {
        fail("send(CTRL_CMD_GETFAMILY)", errno);
        return false;
    }

    uint8_t rbuf[8192];
    ssize_t n = recv(mFd, rbuf, sizeof(rbuf), 0);
    if (n < 0) {
        fail("recv(CTRL_CMD_GETFAMILY)", errno);
        return false;
    }

    struct nlmsghdr* r = (struct nlmsghdr*) rbuf;
    if (!NLMSG_OK(r, (size_t) n)) {
        fail("CTRL_CMD_GETFAMILY: short reply", 0);
        return false;
    }
    if (r->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr* e = (struct nlmsgerr*) NLMSG_DATA(r);
        fail("CTRL_CMD_GETFAMILY", -e->error);
        return false;
    }

    const uint8_t* attrs = (const uint8_t*) NLMSG_DATA(r) + GENL_HDRLEN;
    const size_t attrsLen = NLMSG_PAYLOAD(r, GENL_HDRLEN);

    AttrWalker w(attrs, attrsLen);
    uint16_t type = 0;
    const uint8_t* p = nullptr;
    size_t len = 0;
    while (w.next(type, p, len)) {
        if (type == CTRL_ATTR_FAMILY_ID) {
            uint16_t id = 0;
            if (readU16(p, len, id) && id != 0) {
                mFamily = id;
                return true;
            }
        }
    }

    fail("nl80211 family not found -- is cfg80211 loaded?", 0);
    return false;
}

bool
Nl80211::request(uint8_t cmd, int ifindex, bool dump,
                 const std::vector<uint8_t>& extra,
                 std::vector<std::vector<uint8_t> >& out)
{
    out.clear();

    uint8_t buf[512];
    memset(buf, 0, sizeof(buf));

    struct nlmsghdr* nlh = (struct nlmsghdr*) buf;
    nlh->nlmsg_len   = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type  = mFamily;
    nlh->nlmsg_flags = NLM_F_REQUEST | (dump ? NLM_F_DUMP : 0);
    const uint32_t seq = mSeq++;
    nlh->nlmsg_seq   = seq;
    nlh->nlmsg_pid   = mPortId;

    struct genlmsghdr* gnlh = (struct genlmsghdr*) NLMSG_DATA(nlh);
    gnlh->cmd     = cmd;
    gnlh->version = 0;

    size_t off = NLMSG_ALIGN(nlh->nlmsg_len);

    struct nlattr* na = (struct nlattr*) (buf + off);
    na->nla_type = NL80211_ATTR_IFINDEX;
    na->nla_len  = (uint16_t) (kNlaHdr + 4);
    const uint32_t idx = (uint32_t) ifindex;
    memcpy((uint8_t*) na + kNlaHdr, &idx, 4);
    off += align4(na->nla_len);

    if (!extra.empty() && off + extra.size() <= sizeof(buf)) {
        memcpy(buf + off, extra.data(), extra.size());
        off += extra.size();
    }

    nlh->nlmsg_len = (uint32_t) off;

    if (send(mFd, buf, off, 0) < 0) {
        fail("send(nl80211)", errno);
        return false;
    }

    /*
     * 32 KiB per datagram.  A split wiphy dump keeps each message under a page,
     * and a station reply is a few hundred bytes; the size is slack rather than
     * a requirement.  MSG_TRUNC in the flags would tell us if that were ever
     * wrong, and it is checked below rather than assumed away.
     */
    std::vector<uint8_t> rbuf(32768);
    for (;;) {
        struct iovec iov;
        iov.iov_base = rbuf.data();
        iov.iov_len  = rbuf.size();

        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov    = &iov;
        msg.msg_iovlen = 1;

        const ssize_t n = recvmsg(mFd, &msg, 0);
        if (n < 0) {
            fail("recvmsg(nl80211)", errno);
            return false;
        }
        if (msg.msg_flags & MSG_TRUNC) {
            fail("nl80211 reply truncated -- receive buffer too small", 0);
            return false;
        }

        size_t left = (size_t) n;
        struct nlmsghdr* r = (struct nlmsghdr*) rbuf.data();
        bool done = false;

        for (; NLMSG_OK(r, left); r = NLMSG_NEXT(r, left)) {
            /*
             * Other people's traffic on a shared socket: the sequence number is
             * what distinguishes our reply from a multicast event, and without
             * this check a scan-results notification arriving mid-call would be
             * parsed as a station reply.
             */
            if (r->nlmsg_seq != seq) {
                continue;
            }

            if (r->nlmsg_type == NLMSG_DONE) {
                done = true;
                break;
            }
            if (r->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr* e = (struct nlmsgerr*) NLMSG_DATA(r);
                if (e->error == 0) {
                    done = true;       /* a bare ACK */
                    break;
                }
                fail("nl80211 request", -e->error);
                return false;
            }

            const uint8_t* payload = (const uint8_t*) NLMSG_DATA(r) + GENL_HDRLEN;
            const size_t payloadLen = NLMSG_PAYLOAD(r, GENL_HDRLEN);
            out.push_back(std::vector<uint8_t>(payload, payload + payloadLen));

            if (!(r->nlmsg_flags & NLM_F_MULTI)) {
                done = true;
                break;
            }
        }

        if (done || !dump) {
            break;
        }
    }

    mLastError.clear();
    return true;
}

namespace {

/*
 * One rate_info nest -- the thing `iw` prints as "130.0 MBit/s MCS 14 short GI".
 *
 * The PHY is decided by WHICH MCS attribute is present, not by the bitrate:
 * RATE_INFO_MCS means HT, VHT_MCS means VHT, HE_MCS means HE, EHT_MCS means EHT,
 * and a rate with none of them is a legacy 802.11a/b/g rate.  That is the
 * negotiated PHY for this direction, which is exactly what
 * getConnectionCapabilities is asking for and what no NM property carries.
 *
 * The width attributes are FLAGS -- zero-length attributes whose presence is the
 * value -- so a missing one means 20 MHz rather than unknown.  Width is left at
 * 0 when no flag is present, and the caller decides what "the host did not say"
 * means; see LinkState::channelWidthMhz.
 */
void parseRate(const uint8_t* data, size_t len, RateInfo& out)
{
    AttrWalker w(data, len);
    uint16_t type = 0;
    const uint8_t* p = nullptr;
    size_t n = 0;

    bool haveWidth = false;
    uint32_t rate32 = 0;
    uint16_t rate16 = 0;
    uint8_t  nss = 0;

    while (w.next(type, p, n)) {
        switch (type) {
        case NL80211_RATE_INFO_BITRATE32:
            readU32(p, n, rate32);
            break;
        case NL80211_RATE_INFO_BITRATE:
            readU16(p, n, rate16);
            break;

        case NL80211_RATE_INFO_MCS:
            if (out.phy < Phy::Ht) out.phy = Phy::Ht;
            /*
             * HT encodes the stream count in the MCS index itself: 0-7 is one
             * stream, 8-15 two, 16-23 three, 24-31 four.  There is no HT_NSS
             * attribute, which is why this is derived here and read from an
             * attribute for every other PHY.  bigtab01's live link reads MCS 14,
             * i.e. two streams -- matching the 2x2 card.
             */
            {
                uint8_t mcs = 0;
                if (readU8(p, n, mcs)) {
                    out.nss = (int32_t) (mcs / 8) + 1;
                }
            }
            break;

        case NL80211_RATE_INFO_VHT_MCS:
            if (out.phy < Phy::Vht) out.phy = Phy::Vht;
            break;
        case NL80211_RATE_INFO_VHT_NSS:
            if (readU8(p, n, nss)) out.nss = nss;
            break;

        case NL80211_RATE_INFO_HE_MCS:
            if (out.phy < Phy::He) out.phy = Phy::He;
            break;
        case NL80211_RATE_INFO_HE_NSS:
            if (readU8(p, n, nss)) out.nss = nss;
            break;

        case NL80211_RATE_INFO_EHT_MCS:
            if (out.phy < Phy::Eht) out.phy = Phy::Eht;
            break;
        case NL80211_RATE_INFO_EHT_NSS:
            if (readU8(p, n, nss)) out.nss = nss;
            break;

        case NL80211_RATE_INFO_40_MHZ_WIDTH:
            out.widthMhz = 40;  haveWidth = true; break;
        case NL80211_RATE_INFO_80_MHZ_WIDTH:
            out.widthMhz = 80;  haveWidth = true; break;
        case NL80211_RATE_INFO_80P80_MHZ_WIDTH:
            /*
             * 80+80 is reported to Android as 160: WifiChannelWidthInMhz has a
             * separate value for it (4), but the framework's own
             * getChannelBandwidth maps 4 through unchanged and ThroughputPredictor
             * treats it as the 160 MHz case.  Reporting the honest total here
             * keeps the width and the predictor's view consistent.
             */
            out.widthMhz = 160; haveWidth = true; break;
        case NL80211_RATE_INFO_160_MHZ_WIDTH:
            out.widthMhz = 160; haveWidth = true; break;
        case NL80211_RATE_INFO_320_MHZ_WIDTH:
            out.widthMhz = 320; haveWidth = true; break;

        default:
            break;
        }
    }

    /*
     * BITRATE32 supersedes BITRATE and both are in units of 100 kb/s.  The
     * 16-bit one saturates at 6553.5 Mb/s, which no link here reaches, but it is
     * the only one older drivers send -- so prefer the wide one and fall back.
     */
    const uint32_t units = rate32 ? rate32 : (uint32_t) rate16;
    out.bitrateKbps = (int32_t) (units * 100u);

    /*
     * A rate the driver described without any MCS attribute is a legacy rate --
     * 802.11b's 5.5 Mb/s, say, which is what this machine's rx direction was
     * actually running at.  Only claim that when there WAS a rate: a nest with
     * no bitrate at all is a driver that said nothing.
     */
    if (out.phy == Phy::Unknown && out.bitrateKbps > 0) {
        out.phy = Phy::Legacy;
    }
    if (!haveWidth && out.bitrateKbps > 0) {
        out.widthMhz = 20;
    }
}

void parseStation(const uint8_t* data, size_t len, StationInfo& out)
{
    AttrWalker w(data, len);
    uint16_t type = 0;
    const uint8_t* p = nullptr;
    size_t n = 0;

    while (w.next(type, p, n)) {
        switch (type) {
        case NL80211_ATTR_MAC:
            if (n >= 6) {
                memcpy(out.bssid, p, 6);
            }
            break;

        case NL80211_ATTR_STA_INFO: {
            AttrWalker sw(p, n);
            uint16_t st = 0;
            const uint8_t* sp = nullptr;
            size_t sn = 0;
            while (sw.next(st, sp, sn)) {
                switch (st) {
                case NL80211_STA_INFO_SIGNAL: {
                    uint8_t v = 0;
                    if (readU8(sp, sn, v)) {
                        out.signalDbm = (int32_t) (int8_t) v;
                        out.haveSignal = true;
                    }
                    break;
                }
                case NL80211_STA_INFO_SIGNAL_AVG: {
                    uint8_t v = 0;
                    if (readU8(sp, sn, v)) {
                        out.signalAvgDbm = (int32_t) (int8_t) v;
                    }
                    break;
                }
                case NL80211_STA_INFO_TX_BITRATE:
                    parseRate(sp, sn, out.tx);
                    break;
                case NL80211_STA_INFO_RX_BITRATE:
                    parseRate(sp, sn, out.rx);
                    break;

                /*
                 * The counters are u32 on the wire.  They wrap, and nothing here
                 * pretends otherwise -- Android's getPacketCounters is itself
                 * int32 and the framework uses deltas, so a wrap is a single bad
                 * delta rather than a persistent wrong value.
                 */
                case NL80211_STA_INFO_TX_PACKETS: {
                    uint32_t v = 0;
                    if (readU32(sp, sn, v)) { out.txPackets = v; out.haveCounters = true; }
                    break;
                }
                case NL80211_STA_INFO_TX_FAILED: {
                    uint32_t v = 0;
                    if (readU32(sp, sn, v)) { out.txFailed = v; out.haveCounters = true; }
                    break;
                }
                case NL80211_STA_INFO_TX_RETRIES: {
                    uint32_t v = 0;
                    if (readU32(sp, sn, v)) { out.txRetries = v; out.haveCounters = true; }
                    break;
                }
                case NL80211_STA_INFO_RX_PACKETS: {
                    uint32_t v = 0;
                    if (readU32(sp, sn, v)) { out.rxPackets = v; out.haveCounters = true; }
                    break;
                }
                case NL80211_STA_INFO_CONNECTED_TIME: {
                    uint32_t v = 0;
                    if (readU32(sp, sn, v)) out.connectedTimeSec = v;
                    break;
                }
                default:
                    break;
                }
            }
            break;
        }

        default:
            break;
        }
    }
}

/*
 * One band of a wiphy.  Accumulates rather than assigns, because a split wiphy
 * dump delivers the bands across several messages and because "this radio can do
 * VHT" is true if ANY band can -- which is the question
 * DeviceWiphyCapabilities.isWifiStandardSupported() asks.
 */
void parseBand(const uint8_t* data, size_t len, RadioCaps& out)
{
    AttrWalker w(data, len);
    uint16_t type = 0;
    const uint8_t* p = nullptr;
    size_t n = 0;

    while (w.next(type, p, n)) {
        switch (type) {
        case NL80211_BAND_ATTR_HT_CAPA:
            out.ht = true;
            break;

        case NL80211_BAND_ATTR_HT_MCS_SET: {
            const int32_t s = htStreams(p, n);
            if (s > out.maxTxStreams) out.maxTxStreams = s;
            if (s > out.maxRxStreams) out.maxRxStreams = s;
            break;
        }

        case NL80211_BAND_ATTR_VHT_CAPA: {
            out.vht = true;
            /*
             * VHT capabilities bits 2:3 are the Supported Channel Width Set:
             * 0 = neither 160 nor 80+80, 1 = 160, 2 = 160 and 80+80.  bigtab01's
             * 7265 reads 0 from a capa of 0x038071b0, which `iw phy` prints as
             * "Supported Channel Width: neither 160 nor 80+80" -- so this parser
             * and iw agree on the one radio available to check against.
             */
            uint32_t capa = 0;
            if (readU32(p, n, capa)) {
                const uint32_t cws = (capa >> 2) & 0x3u;
                if (cws >= 1) out.width160 = true;
                if (cws == 2) out.width80p80 = true;
            }
            break;
        }

        case NL80211_BAND_ATTR_VHT_MCS_SET: {
            const int32_t s = vhtStreams(p, n);
            if (s > out.maxTxStreams) out.maxTxStreams = s;
            if (s > out.maxRxStreams) out.maxRxStreams = s;
            break;
        }

        case NL80211_BAND_ATTR_IFTYPE_DATA: {
            /*
             * HE and EHT are per-iftype rather than per-band, so they arrive in a
             * nest of nests: IFTYPE_DATA holds one anonymous entry per iftype
             * group, each with its own capability attributes.  Presence of the
             * PHY capability is the support flag; nothing here needs to decode
             * what is inside it.
             */
            AttrWalker iw(p, n);
            uint16_t it = 0;
            const uint8_t* ip = nullptr;
            size_t in = 0;
            while (iw.next(it, ip, in)) {
                AttrWalker cw(ip, in);
                uint16_t ct = 0;
                const uint8_t* cp = nullptr;
                size_t cn = 0;
                while (cw.next(ct, cp, cn)) {
                    if (ct == NL80211_BAND_IFTYPE_ATTR_HE_CAP_PHY) {
                        out.he = true;
                    } else if (ct == NL80211_BAND_IFTYPE_ATTR_EHT_CAP_PHY) {
                        out.eht = true;
                        /*
                         * 320 MHz exists only in EHT, and only on 6 GHz.  The
                         * bit is in EHT PHY capabilities byte 0 bit 1; checked
                         * rather than inferred from eht, because an EHT radio
                         * without 6 GHz does not have it.
                         */
                        if (cn >= 1 && (cp[0] & 0x02)) {
                            out.width320 = true;
                        }
                    }
                }
            }
            break;
        }

        default:
            break;
        }
    }
}

} /* namespace */

bool
Nl80211::station(int ifindex, StationInfo& out)
{
    out = StationInfo();

    std::lock_guard<std::mutex> guard(mLock);
    if (mFd < 0) {
        return false;
    }

    std::vector<std::vector<uint8_t> > msgs;
    if (!request(NL80211_CMD_GET_STATION, ifindex, true,
                 std::vector<uint8_t>(), msgs)) {
        return false;
    }

    /*
     * A managed-mode interface has exactly one station -- the AP it is
     * associated with -- so the first message is the answer.  An empty dump is
     * the normal, non-error way to learn that the interface is not associated,
     * which is why this returns false without touching mLastError.
     */
    if (msgs.empty()) {
        return false;
    }

    parseStation(msgs[0].data(), msgs[0].size(), out);
    out.valid = true;
    return true;
}

bool
Nl80211::wiphy(int ifindex, RadioCaps& out)
{
    out = RadioCaps();

    std::lock_guard<std::mutex> guard(mLock);
    if (mFd < 0) {
        return false;
    }

    /*
     * SPLIT_WIPHY_DUMP, and it is not an optimisation.
     *
     * A non-dump GET_WIPHY asks the kernel to describe the whole radio in one
     * 4 KiB skb (nl80211_get_wiphy allocates exactly that), and a two-band card
     * with a full channel list does not fit -- the call fails with -ENOBUFS
     * rather than returning a short answer.  The split dump is what `iw` itself
     * uses: the kernel spreads the attributes over several NEW_WIPHY messages,
     * each comfortably inside a page.
     *
     * Splitting means an attribute can appear in more than one message, so
     * everything parseBand() computes is accumulated (OR for flags, max for
     * stream counts) rather than assigned.  That happens to be the right
     * semantics for the question anyway.
     */
    std::vector<uint8_t> extra(kNlaHdr);
    struct nlattr* flag = (struct nlattr*) extra.data();
    flag->nla_type = NL80211_ATTR_SPLIT_WIPHY_DUMP;
    flag->nla_len  = (uint16_t) kNlaHdr;

    std::vector<std::vector<uint8_t> > msgs;
    if (!request(NL80211_CMD_GET_WIPHY, ifindex, true, extra, msgs)) {
        return false;
    }
    if (msgs.empty()) {
        return false;
    }

    for (size_t i = 0; i < msgs.size(); i++) {
        AttrWalker w(msgs[i].data(), msgs[i].size());
        uint16_t type = 0;
        const uint8_t* p = nullptr;
        size_t n = 0;
        while (w.next(type, p, n)) {
            if (type != NL80211_ATTR_WIPHY_BANDS) {
                continue;
            }
            AttrWalker bw(p, n);
            uint16_t bt = 0;
            const uint8_t* bp = nullptr;
            size_t bn = 0;
            while (bw.next(bt, bp, bn)) {
                parseBand(bp, bn, out);
            }
        }
    }

    /*
     * A radio that reported no stream count at all still has one.  Reporting 0
     * would be worse than reporting the floor: ThroughputPredictor takes
     * min(tx, rx) and multiplies by it, so a zero silently predicts zero
     * throughput on a working link.
     */
    if (out.maxTxStreams < 1) out.maxTxStreams = 1;
    if (out.maxRxStreams < 1) out.maxRxStreams = 1;

    out.valid = true;
    return true;
}

} /* namespace wifi */
} /* namespace waydroid */
