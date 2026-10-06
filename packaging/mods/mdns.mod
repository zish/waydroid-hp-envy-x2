# waydroid-ext-mdns -- docs/45-mdns-reflection.md, docs/47-package-split.md
#
# The host's LAN mDNS services, reflected into the container, so Android can
# discover the printer and print to it. Verified end to end on 2026-09-11 with a
# test page out of the Canon, and unpackaged until now for a reason this file
# exists to answer rather than repeat.
#
# WHY THIS WAS THE LAST MODIFICATION TO GET A PACKAGE
#
# docs/45 ends with "Not yet packaged, and why that needs a decision". The
# repository convention is that artifacts/<topic>/install.sh honours
# DESTDIR/PREFIX and doubles as the RPM's %install step -- and the whole change
# here was a two-line edit to a STOCK FEDORA CONFIG FILE. Shipping
# /etc/avahi/avahi-daemon.conf from this package would clobber every future
# Fedora change to it, and avahi has no conf.d directory to drop into instead
# (verified by the method this package now uses for everything else it asks about
# avahi: `grep -a` over the daemon binary finds no such path string).
#
# THE DECISION, AND IT IS THE UNHAPPY ONE
#
# Ship the full file and accept the clobber, or apply the edit idempotently at
# install time. This package does the second, which is what docs/47 and docs/53
# both already prescribed and neither had built. The honest cost, stated once
# here and again in DESCRIPTION: afterwards `rpm -V avahi` reports
# avahi-daemon.conf as modified, because it is. Two of its sixty-odd lines are
# ours and the rest keep tracking avahi's own updates, which is strictly better
# than replacing the file wholesale -- but there is no version of this that
# leaves no trace, and docs/53 says so in those words.
#
# WHAT IS NOT AN EDIT, AND DELIBERATELY SO
#
# The firewalld half. docs/45 captured firewalld-public.xml the way it captured
# avahi-daemon.conf, which made the two look like the same problem; they are not.
# A rich rule goes in through `firewall-cmd --add-rich-rule`, which is additive,
# named, idempotently queryable with --query-rich-rule and removable with
# --remove-rich-rule, so firewalld's zone file stays firewalld's and this package
# owns no part of it. docs/47 called this "the easier of the two" and it is.
#
# It is easier than that doc's table implies, in fact: /etc/firewalld/zones is
# where firewalld puts CUSTOMISATION, and its own shipped defaults live in
# /usr/lib/firewalld/zones. So nothing is being edited out from under another
# package and `rpm -V firewalld` has nothing to say -- unlike avahi, where the
# file really does belong to the package. The repo's own captured copy is the
# evidence: firewalld-public.xml.orig already carried ssh, mdns and
# dhcpv6-client before any of this, so it was the host's customisation and not
# pristine package content. (The two-tier layout is firewalld.zone(5) and is not
# re-verified here -- firewalld is not installed on the dev box -- and it changes
# nothing either way, since firewall-cmd is what writes there in both readings.)
#
# A FIREWALLD SERVICE FILE WOULD HAVE BEEN NICER AND IS WRONG
#
# firewalld reads service definitions out of /usr/lib/firewalld/services, a
# directory a package may legitimately populate, and a service definition may
# carry <source-port port="5353" protocol="udp"/> -- so the rule could have been
# a file rpm owns, added to a zone by name. Rejected on one fact: a firewalld
# service applies to both address families, and the rule docs/45 proved and
# measured the exposure of is family="ipv4". The container has no global IPv6 and
# reflect-ipv is left off for that reason, so the v6 half would be pure widening
# of this host's exposure for no discovery anybody gets. Keeping the verified rule
# verbatim is worth more than owning a file.
#
# THE GATE THAT IS MORE IMPORTANT THAN EITHER HALF
#
# avahi REFUSES TO START on an unknown key in avahi-daemon.conf. docs/45 used
# that as evidence -- "a clean start is a real test, not a silent no-op" -- and
# the other edge of it is what makes this modification dangerous to package
# naively: `reflect-filters` is a 0.9 feature, and on a host whose avahi predates
# it, writing that key does not produce an unfiltered reflector. It produces a
# host with no mDNS at all, including the host's own name resolution, from a
# package install.
#
# The version string cannot be the test. Fedora's 0.9~rc2 reports `0.8` from
# --version and the feature demonstrably works (docs/45). So the reconciler greps
# the daemon binary for each key before it writes anything, refuses the whole
# change if any key is missing, and says which. And if the daemon still will not
# come back after the edit, the edit is rolled back and avahi is restarted on the
# configuration it had a second earlier. Nothing else in this project edits a host
# daemon's own config file; nothing else has needed a self-heal, and this does.
#
# It refuses rather than dropping the unsupported key on purpose. Without
# reflect-filters the reflector advertises Android's own _adb._tcp to the LAN at
# 192.168.240.112, an address nothing out there can route to -- docs/45 is explicit
# that the filter is "not only a noise control". Silently degrading to that is a
# worse outcome than not working, so it is not on offer.
#
# WHY A UNIT AT ALL, WHEN NOTHING REGENERATES THIS FILE
#
# Unlike waydroid_base.prop and the overlay, /etc/avahi/avahi-daemon.conf is not
# state and nothing rewrites it. The narrower reason stands anyway: avahi owns the
# file, so an avahi update whose own copy has changed drops an .rpmnew beside
# ours, and an administrator who takes the new one has turned the reflector off
# with nothing to tell them until somebody tries to print. The unit notices at the
# next boot. It is also the half that works on the rpm-ostree target, where a
# %post runs against the compose and `firewall-cmd` in a compose means nothing --
# there the reboot `rpm-ostree install` already requires is when the work happens.
#
# docs/47 asks the non-overlay reconcilers for "a %post and an ExecStartPre". The
# ExecStartPre half is not honoured literally and should not be: mDNS is discovery
# over a live socket, not something Android latches at container start -- the Canon
# appeared in a session that was already running -- so there is nothing for
# waydroid-container.service to be ordered against. A WantedBy=multi-user.target
# oneshot, After= avahi and firewalld, is the same guarantee without inventing a
# dependency between this package and the container.
#
# WHAT THE %post MAY AND MAY NOT DO
#
# It runs the reconciler with --no-restart. The firewall half applies live either
# way, because adding a rich rule costs nothing and needs no restart -- and the
# reconciler never calls `firewall-cmd --reload`, which flushes and rebuilds; the
# runtime rule is added directly and the permanent one written alongside it, which
# is the order docs/45 made the change in and for the reason it gives.
#
# The avahi half stops at writing the file, and the tool says on stderr --
# unsuppressable by --quiet -- that the daemon is still running the old
# configuration and what one command applies it. That is the same choice
# waydroid-ext-overlay-sync makes about the container restart: a package names the
# restart and lets a human choose. avahi is not even our daemon, which makes the
# case easier rather than harder.
#
# WHAT AN UNINSTALL DOES NOT DO
#
# It does not put avahi-daemon.conf back, and %preun says so while the tool that
# can is still installed. `waydroid-mdns-reflector --revert` is the undo: it
# restores the copy taken before the first edit, restarts avahi, and removes the
# rich rule from both the runtime and permanent configurations. Doing that from a
# scriptlet instead was rejected twice over -- on rpm-ostree it would run against
# the compose, and reverting another package's config file without being asked is
# not a package's decision to make when the administrator may have edited those
# same two lines since.
#
# WHAT IT DOES NOT SHIP
#
#   bin/mdns-listen.py. It is how every measurement in docs/45 was taken and it
#     is genuinely the tool for answering "did the reflection arrive?", but it is
#     a diagnostic and belongs to the `tools` package docs/53 and docs/63 both
#     name as unwritten. DESCRIPTION points at it in the checkout rather than
#     smuggling it in here.
#   enabled_print_services. docs/45 set it by hand to test; it lives in Android's
#     settings providers in /data, which no package can own (docs/53), and both
#     print services bind without it once a human opens the print settings.
#   Anything about the Mopria Print Service or com.android.bips. Both are already
#     in the image. The modification is the path they discover over.
#
# WHAT WAS ALSO RULED OUT, AND IS IN DESCRIPTION BECAUSE IT KEEPS BEING
# REDISCOVERED
#
# smcroute, igmpproxy and pimd: 224.0.0.251 is in the link-local control block
# routers must not forward at any TTL, so this is the wrong layer, not a
# misconfiguration. Bridging or macvlan onto the LAN interface: both radios here
# are Wi-Fi STA and an AP drops frames with unexpected source MACs. Pointing
# Waydroid's dnsmasq at avahi: that is .local name resolution, and NsdManager does
# real multicast browsing. docs/45 has all three with the evidence.

VERSION=1.0.0
RELEASE=1
KIND=host

# One POSIX shell script, one unit, one key=value file. The service names in the
# filter list are text, and the CPU this runs on has nothing to do with it --
# unlike waydroid-ext-dexopt, whose values genuinely name one machine's topology.
ARCH=noarch

SUMMARY="Reflect the host's LAN mDNS into Waydroid, so Android can find the printer"

# Every payload file carries an SPDX GPL-3.0-or-later header and none of it is
# derived from avahi's source. The two avahi-daemon.conf copies in the source
# tarball are avahi's own file under LGPL-2.1-or-later and are build-time test
# fixtures: the %check reads them, nothing installs them, and no byte of either
# is in the binary package.
LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason as every other package here that ships a unit.
BUILDREQUIRES="systemd-rpm-macros"

# avahi is hard, and is the only hard dependency. Its daemon is what reflects,
# its config file is what this package edits, and without it the reconciler has
# nothing to reconcile and says so rather than working: docs/47's test is whether
# the package without the dependency is worse than stock, and here it is simply
# inert, but a package whose entire subject is another package's configuration
# should name that package.
#
# Everything the reconciler actually runs:
#   gawk        the section-aware merge. Unguarded, and the one piece that cannot
#               be done in shell without getting the sections wrong -- which is
#               the failure mode that stops avahi starting.
#   grep        the capability gate greps the daemon binary (grep -a), and the
#               config parser uses it. Unguarded.
#   sed         trimming in the config parser. Unguarded.
#   diffutils   cmp decides whether the file is rewritten at all, and so whether
#               avahi is restarted; diff renders the drift --verify reports. It is
#               diffutils and not coreutils.
#   coreutils   mktemp, cp, cat, install, printf, rm.
#   systemd     systemctl is-active/restart, and the unit machinery.
REQUIRES="avahi
systemd
coreutils
diffutils
gawk
grep
sed"

# firewalld is weak, by docs/47's test. Without it the reflector still serves
# every client that queries properly from port 5353 -- which is Android's own
# platform mDNS stack, and therefore com.android.bips and the Canon appearing in
# Default Print Service. What is lost is the one-shot (legacy unicast) querier,
# the Mopria Print Service among them. Degraded, not worse than stock, and the
# reconciler says plainly that it found no firewall-cmd rather than failing.
#
# A host that filters inbound UDP by some other means needs the equivalent of the
# rule by hand; there is no way for a weak dependency to express that, so the tool
# prints it.
#
# policycoreutils for restorecon, guarded with command -v, and only on the manual
# install path -- the RPM's files are labelled by the compose or by rpm itself.
RECOMMENDS="firewalld
policycoreutils"

DOCS="docs/45-mdns-reflection.md
docs/47-package-split.md"

DESCRIPTION="Makes the printers, Chromecasts and other mDNS services on the host's LAN
discoverable from inside the Waydroid container, which is what Android needs
before it can print.

The container is on its own L2 segment behind NAT, and mDNS cannot be routed
to it: 224.0.0.251 is in the link-local control block that routers must not
forward at any TTL. So this is not forwarding and no multicast-routing daemon
can do it -- smcroute, igmpproxy and pimd are the wrong layer rather than
misconfigured. What works is avahi's reflector, which re-originates the query
on the other segment at the application layer, and that is what this package
configures. Discovery is only ever a name, a port and an address, and the
reflector passes the address through unmodified, so Android ends up with the
print server's real LAN address and makes an ordinary unicast connection to it
through the container's existing gateway.

TWO CHANGES, NOT ONE. The reflector is half of it. The other half is a
firewalld rule accepting UDP by source port 5353, without which a client that
sends one-shot (legacy unicast) mDNS queries discovers nothing at all: avahi
re-originates such a query from an unpredictable ephemeral port, the answer
comes back to that port, and it matches no rule and no connection-tracking
entry. The Mopria Print Service asks that way. Android's own platform mDNS
stack, and so the built-in print service, queries from port 5353 and is
unaffected. Understand what the rule costs: it accepts UDP from any host on the
local network willing to send FROM port 5353 to ANY high port on this machine.
That is a real, if small, widening of this host's exposure, and it is the only
rule that serves one-shot clients through a reflector. Set firewall-zone=none
in /etc/waydroid-mdns.conf to decline it and keep the rest.

IT EDITS A FILE IT DOES NOT OWN, AND THERE IS NO WAY AROUND IT.
/etc/avahi/avahi-daemon.conf belongs to the avahi package and has no drop-in
directory, so two keys in its [reflector] section are changed in place. This
package does not replace the file: the other sixty lines are left exactly as
avahi shipped them and go on receiving avahi's own updates. Afterwards 'rpm -V
avahi' reports that file as modified, because it is. A copy of it as it was
before the first edit is kept beside it as avahi-daemon.conf.pre-waydroid-ext,
and 'waydroid-mdns-reflector --revert' puts it back and removes the firewall
rule. Uninstalling this package does NOT do that by itself, deliberately: by
then an administrator may have edited those same lines, and that is not a
decision a scriptlet should take.

SAFE TO RE-RUN, AND IT CHECKS BEFORE IT WRITES. The merge replaces each key
where it already stands rather than appending, so running it twice changes
nothing. Before writing anything it greps the avahi daemon binary for every key
it is about to set, because avahi refuses to START on a key it does not know --
so on a host with an older avahi this refuses to proceed and says which key,
instead of leaving the machine with no mDNS at all. The version string cannot
be used for that test: Fedora's 0.9~rc2 package reports 0.8 and the feature
works. If the daemon somehow still fails to start, the edit is rolled back and
avahi is restarted on the configuration it had.

NOTHING RESTARTS. Not the container -- mDNS is discovery over a live socket, so
there is nothing to restart for, and on a kiosk host a container restart drops
the session to the greeter. Not avahi either, when the change arrives by
package install: the file is written and the one command that applies it is
printed. A boot-time unit reconciles again on every boot, which is what catches
an avahi update that dropped a new config file next to ours.

WHAT TO EXPECT. Measured on the reference host: a filtered reflector delivers
the print server's full record set into the container in under a second, and
the service types reflected are the six in /etc/waydroid-mdns.conf -- printing,
Chromecast and AirPlay. Two things the filter does not do, both worth knowing
before editing it: queries cross regardless of the filter, so it is not a
privacy boundary, and the service-type meta-query is not in the list, so a
client that enumerates types before browsing them finds nothing until
_services._dns-sd._udp.local is added.

Discovery in the other direction is not provided and cannot be. The reflector
would advertise Android's services to the LAN at a container address nothing
out there can route to, and the filter list is what keeps those useless records
off the network. Fixing it would need DNAT plus rewriting the records avahi
reflects verbatim.

To see it working from inside the container's own network namespace, which is
the only place the answer means anything, bin/mdns-listen.py in this project's
repository sends a real multicast query and prints what comes back.
docs/45-mdns-reflection.md has the command and the packet captures."

# The two avahi-daemon.conf copies and firewalld-public.xml are here as %check
# fixtures, not as payload. selftest.sh reproduces the verified file from the
# stock one and ties the rule the tool adds to the zone file that was captured
# when the probe went from silence to a complete answer.
#
# firewalld-public.xml.orig is deliberately absent: it is the pre-change record
# and nothing tests against it, so putting it in the tarball would imply the
# package has a use for it.
SOURCES="artifacts/mdns/install.sh
artifacts/mdns/selftest.sh
artifacts/mdns/waydroid-mdns-reflector
artifacts/mdns/waydroid-mdns-reflector.service
artifacts/mdns/waydroid-mdns.conf
artifacts/mdns/avahi-daemon.conf
artifacts/mdns/avahi-daemon.conf.orig
artifacts/mdns/firewalld-public.xml"

# UNITDIR and SYSCONFDIR are both passed because the installer defaults both to
# /etc -- correct for a hand install on an immutable host, and wrong for a
# package in the unit's case: a packaged unit belongs in /usr/lib/systemd/system,
# which leaves /etc/systemd/system free for an admin drop-in that is then
# unambiguously theirs. SYSCONFDIR is passed anyway, even though %{_sysconfdir}
# is the installer's own default, because the @SYSCONFDIR@ substituted into the
# tool and the unit has to be the directory %files actually claims; letting that
# agree by coincidence is how an earlier installer here shipped a literal
# @BINDIR@ and failed silently (docs/25).
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    SYSCONFDIR=%{_sysconfdir} sh artifacts/mdns/install.sh'

# The merge is the only part of this project that edits another package's file,
# and it has a failure mode worse than not working: a key written into the wrong
# section of avahi-daemon.conf stops the daemon starting, which takes the host's
# own mDNS with it. The flat drop-the-key-and-append merge that is correct in
# artifacts/dexopt/install.sh would do exactly that here -- appending
# enable-reflector=yes lands it inside [rlimits].
#
# So the check is strict: render the stock Fedora avahi-daemon.conf through the
# merge and require byte-for-byte equality with the file that was on the host when
# a test page came out of the Canon on 2026-09-11. Nine more cases cover
# idempotence, the absent-section and duplicate-key paths, both refusals, the
# capability gate in both directions, and the firewalld rule against the captured
# zone file. No avahi, no firewalld, no root and no network.
#
# This is the first host-kind modification to declare a CHECK. The variable was in
# gen-spec.sh's defaults and written only by the overlay arm, so until that was
# fixed a host mod could declare a %check and have it silently dropped -- the same
# class of gap the generator already records about GLOBALS.
CHECK='%check
sh artifacts/mdns/selftest.sh'

# Three files and one enable symlink, verified by staging into a scratch DESTDIR.
#
# %config(noreplace) on the values, and it is the point rather than a formality:
# the filter list is the one thing here an administrator legitimately tunes --
# adding _raop for an AirPlay speaker, or the _services._dns-sd meta-query for a
# client that enumerates -- and plain %config would move their edit to .rpmsave on
# every upgrade and quietly reinstate ours.
#
# Under /etc and not /usr/share, unlike waydroid-ext-dexopt's values, and
# deliberately: packaging/test-install.sh's rule is that anything under /etc must
# be %config because /etc is where an administrator edits, and the corollary is
# that a %config anywhere else fails it -- dexopt's does, because the .rpmsave rpm
# leaves behind keeps the directory above it from being removed on erase. So this
# file is flat at /etc/waydroid-mdns.conf with no directory of ours around it, and
# there is nothing left behind. /etc is also the right place on the rpm-ostree
# target for the opposite reason to /usr: it is writable there and three-way
# merged across deployments, so an edit survives both an upgrade and a rollback.
#
# The .wants directory is ours to declare, the same situation waydroid-ext-pwd's
# default.target.wants and waydroid-ext-overlay-sync's multi-user.target.wants are
# in: systemd owns %{_unitdir}, and nothing owns the .wants under it until a
# package drops a symlink in.
PAYLOAD_FILES='%{_bindir}/waydroid-mdns-reflector
%{_unitdir}/waydroid-mdns-reflector.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-mdns-reflector.service
%config(noreplace) %{_sysconfdir}/waydroid-mdns.conf'

# --no-restart, for the reason in the header: this package writes avahi's config
# and names the restart rather than restarting another package's daemon inside an
# rpm transaction. The firewall half applies live regardless, because a rich rule
# costs nothing to add and needs no restart.
#
# Inert on the rpm-ostree target by construction -- a scriptlet there runs against
# the compose, where firewall-cmd has no running firewalld to talk to -- which is
# why the boot unit and not this is the mechanism. docs/47.
#
# `|| :` because no scriptlet may fail a transaction, and the reconciler exits
# non-zero on exactly the cases where it has refused to act: an avahi too old for
# a key it was asked to set, or a daemon that would not restart. Both are states
# the next boot's unit reports again, with the journal to put it in.
#
# $1 -eq 0 on %preun because it also runs on upgrade, where none of this applies.
# The revert is NAMED and not run: see the header. --verify is run while the tool
# that can answer is still installed, because a second later it is gone.
SCRIPTLETS='%post
%{_bindir}/waydroid-mdns-reflector --quiet --no-restart || :

%preun
if [ $1 -eq 0 ]; then
    echo "mdns: /etc/avahi/avahi-daemon.conf stays as it is -- removing this" >&2
    echo "  package does not undo an edit to a file belonging to avahi." >&2
    echo "  To undo it, before this package goes away:" >&2
    echo "      waydroid-mdns-reflector --revert" >&2
    %{_bindir}/waydroid-mdns-reflector --verify || :
fi'
