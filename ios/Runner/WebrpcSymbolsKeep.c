// Keep gomobile C ABI symbols alive under Release dead-code stripping.
// Dart FFI resolves them at runtime via dlsym(DynamicLibrary.process());
// the linker otherwise drops them as unreferenced.

#include <stdint.h>

typedef uintptr_t GoUintptr;

extern GoUintptr WebrpcClient_New(char* token, char* passwd, char* permission);
extern int WebrpcClient_LoginStatus(GoUintptr handle);
extern int WebrpcClient_GetReceivePort(GoUintptr handle);
extern unsigned int WebrpcClient_OpenSession(GoUintptr handle, char* toToken, char* permission);
extern unsigned short WebrpcClient_SessionSize(GoUintptr handle);
extern char* WebrpcClient_TarTokenBySession(GoUintptr handle, unsigned int sessionId);
extern int WebrpcClient_CloseSession(GoUintptr handle, unsigned int sessionId);
extern int WebrpcClient_SendData(GoUintptr handle, unsigned int sessionId, char* data, int dataLen, long long timeOut);
extern int WebrpcClient_SendFile(GoUintptr handle, unsigned int sessionId, char* filePath);
extern int WebrpcClient_SendFileAsync(GoUintptr handle, unsigned int sessionId, const char* filePath, void* done);
extern void WebrpcClient_Free(GoUintptr handle);

__attribute__((used, visibility("default")))
static void* const kWebrpcKeep[] = {
    (void*)&WebrpcClient_New,
    (void*)&WebrpcClient_LoginStatus,
    (void*)&WebrpcClient_GetReceivePort,
    (void*)&WebrpcClient_OpenSession,
    (void*)&WebrpcClient_SessionSize,
    (void*)&WebrpcClient_TarTokenBySession,
    (void*)&WebrpcClient_CloseSession,
    (void*)&WebrpcClient_SendData,
    (void*)&WebrpcClient_SendFile,
    (void*)&WebrpcClient_SendFileAsync,
    (void*)&WebrpcClient_Free,
};
