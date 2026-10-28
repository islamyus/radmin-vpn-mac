// Synthetic keychain fixture only. Never opens the user's login keychain.
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#ifndef FIXTURE_VERSION
#define FIXTURE_VERSION 1
#endif
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    SecKeychainSetUserInteractionAllowed(false);
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(argv[1], &keychain);
    if (status != errSecSuccess) return 3;
    const char *account = "synthetic-only";
    const char *payload = "fixture-only-not-a-device-credential";
    if (strcmp(argv[2], "create") == 0) {
        status = SecKeychainAddGenericPassword(keychain, (UInt32)strlen(argv[3]), argv[3],
            (UInt32)strlen(account), account, (UInt32)strlen(payload), payload, NULL);
    } else {
        UInt32 size = 0; void *data = NULL;
        status = SecKeychainFindGenericPassword(keychain, (UInt32)strlen(argv[3]), argv[3],
            (UInt32)strlen(account), account, &size, &data, NULL);
        if (status == errSecSuccess) {
            if (size != strlen(payload) || memcmp(data, payload, size)) status = errSecDecode;
            SecKeychainItemFreeContent(NULL, data);
        }
    }
    CFRelease(keychain);
    printf("Synthetic version %d: status %d; user interaction disabled\n", FIXTURE_VERSION, (int)status);
    return status == errSecSuccess ? 0 : 1;
}
