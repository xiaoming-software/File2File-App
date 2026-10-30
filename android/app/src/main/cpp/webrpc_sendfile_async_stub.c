// Placeholder for ABIs without libwebrpc.so (e.g. x86_64 host cmake).
// Real devices use arm64-v8a / armeabi-v7a builds of webrpc_sendfile_async.c.
void webrpc_sendfile_async_unsupported_abi(void) {}
