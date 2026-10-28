// SPDX-License-Identifier: GPL-3.0-only
// Stable per-user Keychain reader. No networking, root privileges or files.
// Credentials travel only through pipes to a verified, signed parent engine.
#include <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef ENGINE_REQUIREMENT
#error ENGINE_REQUIREMENT must pin the engine identifier and certificate
#endif
#ifndef IDENTITY_SERVICE
#define IDENTITY_SERVICE "dev.radminvpn.mac.native.identity.v2"
#endif
#ifndef LEGACY_SERVICE
#define LEGACY_SERVICE "dev.radminvpn.mac.native.identity"
#endif
#define LIMIT 65536
enum { MISSING=10, UNAVAILABLE=11, CALLER_REJECTED=12, INVALID=13 };
#ifdef FIXTURE_KEYCHAIN
static SecKeychainRef fixture_keychain=NULL;
#endif

static void wipe(void *p, size_t n) {
    volatile unsigned char *b=p;
    while (n--) *b++=0;
}
static int caller_allowed(void) {
    struct stat out;
    pid_t parent=getppid();
    if (getuid()==0 || getuid()!=geteuid() || parent<=1 ||
        fstat(STDOUT_FILENO,&out)!=0 || !S_ISFIFO(out.st_mode)) return 0;
    CFNumberRef pid=CFNumberCreate(NULL,kCFNumberIntType,&parent);
    const void *keys[]={kSecGuestAttributePid}; const void *values[]={pid};
    CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,values,1,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    SecCodeRef code=NULL; SecRequirementRef requirement=NULL;
    OSStatus s=SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&code);
    if (!s) s=SecRequirementCreateWithString(CFSTR(ENGINE_REQUIREMENT),kSecCSDefaultFlags,&requirement);
    if (!s) s=SecCodeCheckValidity(code,kSecCSStrictValidate,requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(attrs); CFRelease(pid);
    return s==errSecSuccess && getppid()==parent;
}
static OSStatus find(const char *service, CFStringRef account, CFDataRef *bytes) {
    const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount,kSecReturnData};
    CFStringRef name=CFStringCreateWithCString(NULL,service,kCFStringEncodingUTF8);
    const void *values[]={kSecClassGenericPassword,name,account,kCFBooleanTrue};
    CFDictionaryRef q=CFDictionaryCreate(NULL,keys,values,4,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
#ifdef FIXTURE_KEYCHAIN
    CFMutableDictionaryRef scoped=CFDictionaryCreateMutableCopy(NULL,0,q);
    const void *only[]={fixture_keychain};
    CFArrayRef search=CFArrayCreate(NULL,only,1,&kCFTypeArrayCallBacks);
    CFDictionarySetValue(scoped,kSecMatchSearchList,search);
    CFRelease(search); CFRelease(q); q=scoped;
#endif
    CFTypeRef result=NULL; OSStatus s=SecItemCopyMatching(q,&result);
    if (s==0 && (!result || CFGetTypeID(result)!=CFDataGetTypeID() ||
        CFDataGetLength(result)<1 || CFDataGetLength(result)>LIMIT)) s=errSecDecode;
    if (s==0) *bytes=(CFDataRef)result;
    else if (result) CFRelease(result);
    CFRelease(q); CFRelease(name); return s;
}
static OSStatus add(CFStringRef account, CFDataRef bytes) {
    const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount,kSecValueData};
    const void *values[]={kSecClassGenericPassword,CFSTR(IDENTITY_SERVICE),account,bytes};
    CFDictionaryRef q=CFDictionaryCreate(NULL,keys,values,4,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
#ifdef FIXTURE_KEYCHAIN
    CFMutableDictionaryRef scoped=CFDictionaryCreateMutableCopy(NULL,0,q);
    CFDictionarySetValue(scoped,kSecUseKeychain,fixture_keychain);
    CFRelease(q); q=scoped;
#endif
    OSStatus s=SecItemAdd(q,NULL); CFRelease(q);
    if (s==errSecDuplicateItem) {
        CFDataRef existing=NULL; s=find(IDENTITY_SERVICE,account,&existing);
        if (!s) { if (!CFEqual(existing,bytes)) s=errSecDuplicateItem; CFRelease(existing); }
    }
    return s;
}
static int emit(CFDataRef bytes) {
    const unsigned char *b=CFDataGetBytePtr(bytes); size_t n=(size_t)CFDataGetLength(bytes);
    while (n) { ssize_t k=write(STDOUT_FILENO,b,n);
        if (k<0 && errno==EINTR) continue;
        if (k<=0) return UNAVAILABLE;
        b+=k; n-=(size_t)k;
    }
    return 0;
}
int main(int argc,char **argv) {
    if (argc!=3 || argv[2][0]!='/' || strlen(argv[2])>4096) return INVALID;
    int reading=strcmp(argv[1],"read")==0, migrating=strcmp(argv[1],"migrate")==0;
    int storing=strcmp(argv[1],"store")==0;
    if ((!reading && !migrating && !storing) || !caller_allowed()) return CALLER_REJECTED;
    SecKeychainSetUserInteractionAllowed(false);
#ifdef FIXTURE_KEYCHAIN
    if (SecKeychainOpen(FIXTURE_KEYCHAIN,&fixture_keychain)!=errSecSuccess) return UNAVAILABLE;
#endif
    CFStringRef account=CFStringCreateWithCString(NULL,argv[2],kCFStringEncodingUTF8);
    if (!account) return INVALID;
    CFDataRef bytes=NULL; OSStatus s=0;
    if (storing) {
        unsigned char *input=malloc(LIMIT+1); if (!input) return UNAVAILABLE;
        size_t count=0;
        while (count<LIMIT+1) { ssize_t n=read(STDIN_FILENO,input+count,LIMIT+1-count);
            if (n<0 && errno==EINTR) continue;
            if (n<0) { wipe(input,count); free(input); return UNAVAILABLE; }
            if (!n) break; count+=(size_t)n;
        }
        if (!count || count>LIMIT) { wipe(input,count); free(input); return INVALID; }
        bytes=CFDataCreate(NULL,input,(CFIndex)count); wipe(input,count); free(input);
        s=add(account,bytes);
    } else {
        s=find(IDENTITY_SERVICE,account,&bytes);
        if (migrating && s==errSecItemNotFound) {
            // The only interactive operation: copy the old item after OS approval.
            // Its data/ACL are never replaced or removed.
#ifndef FIXTURE_KEYCHAIN
            SecKeychainSetUserInteractionAllowed(true);
#endif
            s=find(LEGACY_SERVICE,account,&bytes);
            SecKeychainSetUserInteractionAllowed(false);
            if (!s) s=add(account,bytes);
        }
    }
    int result=s==0?0:(s==errSecItemNotFound?MISSING:UNAVAILABLE);
    if (!result && !storing) result=emit(bytes);
    if (bytes) CFRelease(bytes);
#ifdef FIXTURE_KEYCHAIN
    CFRelease(fixture_keychain);
#endif
    CFRelease(account); return result;
}
