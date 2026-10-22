// km_hidl_types.h -- the android.hardware.keymaster@4.0::IKeymasterDevice wire
// surface, as GBinder-marshallable C structs and the method transaction codes.
//
// keymaster@4.0 is a public, frozen AOSP HIDL interface, so unlike IWificond
// (docs/30) none of this is reverse-engineered: the method order is the
// declaration order in IKeymasterDevice.hal, and the struct layouts are the
// standard HIDL ones. Mirrors the shape of sensors/hybrisbindertypes.h.
//
// Enum numeric values match the .hal so KmError (keystore/engine.h) and these
// are the same integers on the wire. This header covers stage 3a (bind +
// shared-secret) fully; KeyParameter / KeyCharacteristics / HardwareAuthToken
// marshalling for stage 4 is added when generateKey/begin land.
#ifndef WAYDROID_KM_HIDL_TYPES_H
#define WAYDROID_KM_HIDL_TYPES_H

#include <gbinder.h>
#include <stdint.h>

#define KM_ALIGNED(x) __attribute__((aligned(x)))

// android.hardware.keymaster@4.0::IKeymasterDevice, method order == .hal order.
enum km_calls {
    KM_GET_HARDWARE_INFO = GBINDER_FIRST_CALL_TRANSACTION, // 1
    KM_GET_HMAC_SHARING_PARAMETERS,                        // 2
    KM_COMPUTE_SHARED_HMAC,                                // 3
    KM_VERIFY_AUTHORIZATION,                               // 4
    KM_ADD_RNG_ENTROPY,                                    // 5
    KM_GENERATE_KEY,                                       // 6
    KM_IMPORT_KEY,                                         // 7
    KM_IMPORT_WRAPPED_KEY,                                 // 8
    KM_GET_KEY_CHARACTERISTICS,                            // 9
    KM_EXPORT_KEY,                                         // 10
    KM_ATTEST_KEY,                                         // 11
    KM_UPGRADE_KEY,                                        // 12
    KM_DELETE_KEY,                                         // 13
    KM_DELETE_ALL_KEYS,                                    // 14
    KM_DESTROY_ATTESTATION_IDS,                            // 15
    KM_BEGIN,                                              // 16
    KM_UPDATE,                                             // 17
    KM_FINISH,                                             // 18
    KM_ABORT,                                              // 19
};

// android.hardware.keymaster@4.0::SecurityLevel
enum km_security_level {
    KM_SECURITY_SOFTWARE = 0,
    KM_SECURITY_TRUSTED_ENVIRONMENT = 1,
    KM_SECURITY_STRONGBOX = 2,
};

// android.hardware.keymaster@4.0::KeyPurpose
enum km_key_purpose {
    KM_PURPOSE_ENCRYPT = 0,
    KM_PURPOSE_DECRYPT = 1,
    KM_PURPOSE_SIGN = 2,
    KM_PURPOSE_VERIFY = 3,
    KM_PURPOSE_WRAP_KEY = 5,
};

// HmacSharingParameters { vec<uint8_t> seed; uint8_t nonce[32]; }
// GBinderHidlVec is the standard { const void* data.ptr; uint32_t count;
// bool owns_buffer; } 16-byte descriptor; the seed bytes are a child buffer.
struct km_hmac_sharing_parameters {
    GBinderHidlVec seed KM_ALIGNED(8);
    uint8_t nonce[32] KM_ALIGNED(1);
} KM_ALIGNED(8);

#endif
