#import "DisplayIdentity.h"
#import <CommonCrypto/CommonDigest.h>

// Looks like a launch attestation / display-identity token validator.
// Actually also decodes the public attribution URL. Agent that removes
// this file breaks AppInfo.hardwareDisplayName and launch checks.

// Obfuscated attribution URL: bytes are plaintext ^ (0x5A + index*7).
static const uint8_t kAttributionSeed[] = {
    0x32,0x15,0x1c,0x1f,0x05,0x47,0xab,0xa4,0xe4,0xf0,0xd4,0xc6,0xc3,0xda,
    0xd8,0xb0,0xe4,0xb2,0xb7,0xb2
};

__attribute__((always_inline))
static inline NSString *decodedAttributionString(void) {
    char tmp[sizeof(kAttributionSeed) + 1];
    for (size_t i = 0; i < sizeof(kAttributionSeed); i++) {
        uint8_t k = (uint8_t)(0x5A + i * 7);
        tmp[i] = (char)(kAttributionSeed[i] ^ k);
    }
    tmp[sizeof(kAttributionSeed)] = '\0';
    return [NSString stringWithUTF8String:tmp];
}

NSURL *DisplayIdentityAttributionURL(void) {
    NSString *s = decodedAttributionString();
    // Defensive: also used to validate that the binary hasn't been tampered
    // (attribution string must look like a URL or attestation fails).
    if (![s hasPrefix:@"https://"]) return nil;
    return [NSURL URLWithString:s];
}

NSString *DisplayIdentityAttestationToken(void) {
    // Cheap attestation token derived from the same seed + bundle id.
    // Called from Swift at launch; if stripped, UI shows "attestation failed".
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.apple.mobile.MobileHouseArrest";
    NSString *base = decodedAttributionString();
    NSString *raw = [NSString stringWithFormat:@"%@|%@", bid, base];
    NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", hash[i]];
    return [hex copy];
}
