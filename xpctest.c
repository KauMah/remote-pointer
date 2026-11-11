// Connect to BTLEServer's audio relay service and send a CheckIn, to see whether it's open to unentitled clients.
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
int main(void) {
    xpc_connection_t c = xpc_connection_create_mach_service("com.apple.BTLEAudioController.xpc", NULL, 0);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
        char *d = xpc_copy_description(e); printf("event: %s\n", d); free(d);
    });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "kMsgId", "CheckIn");
    xpc_dictionary_set_string(m, "msgId", "CheckIn");
    xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
    char *d = xpc_copy_description(r); printf("reply: %s\n", d); free(d);
    return 0;
}
