// Private implementation detail. Never import from the app's Swift bridging header.
// ABI source: Apple MacOSX11.3.sdk xpc/{xpc,connection}.h, mirrored at
// phracker/MacOSX-SDKs commit 041600eda65c6a668f66cb7d56b7d1da3e8bcc93.
// See Validation/ApelinNative/XPC-ABI.md for hashes, signatures and evidence.
#ifndef MinisApelinXPCPrivate_h
#define MinisApelinXPCPrivate_h

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <os/object.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#if __has_include(<xpc/xpc.h>)
#import <xpc/xpc.h>
#else
#if !OS_OBJECT_USE_OBJC || !__has_feature(objc_arc) || !__BLOCKS__
#error This private XPC subset requires Objective-C ARC and blocks.
#endif
// Match Apple's Objective-C object model, including ARC-managed connections.
OS_OBJECT_DECL(xpc_object);
typedef xpc_object_t xpc_connection_t;
typedef const struct _xpc_type_s *xpc_type_t;
typedef void (^xpc_handler_t)(xpc_object_t object);

// These are opaque exported objects, NOT pointer variables or integer tags.
extern const struct _xpc_type_s _xpc_type_bool;
extern const struct _xpc_type_s _xpc_type_array;
extern const struct _xpc_type_s _xpc_type_dictionary;
extern const struct _xpc_type_s _xpc_type_error;
#define XPC_TYPE_BOOL (&_xpc_type_bool)
#define XPC_TYPE_ARRAY (&_xpc_type_array)
#define XPC_TYPE_DICTIONARY (&_xpc_type_dictionary)
#define XPC_TYPE_ERROR (&_xpc_type_error)

extern xpc_type_t xpc_get_type(xpc_object_t object);
extern bool xpc_bool_get_value(xpc_object_t object);
extern size_t xpc_array_get_count(xpc_object_t array);
extern xpc_object_t xpc_dictionary_create(const char *const *keys,
    const xpc_object_t *values, size_t count) OS_OBJECT_RETURNS_RETAINED;
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key, const char *value);
extern void xpc_dictionary_set_int64(xpc_object_t dictionary, const char *key, int64_t value);
extern void xpc_dictionary_set_data(xpc_object_t dictionary, const char *key, const void *bytes, size_t length);
extern xpc_object_t xpc_dictionary_get_value(xpc_object_t dictionary, const char *key);
extern const char *xpc_dictionary_get_string(xpc_object_t dictionary, const char *key);
extern const void *xpc_dictionary_get_data(xpc_object_t dictionary, const char *key, size_t *length);
extern void xpc_connection_set_event_handler(xpc_connection_t connection, xpc_handler_t handler);
extern void xpc_connection_activate(xpc_connection_t connection);
extern void xpc_connection_cancel(xpc_connection_t connection);
extern void xpc_connection_send_message_with_reply(xpc_connection_t connection,
    xpc_object_t message, dispatch_queue_t replyq, xpc_handler_t handler);
#endif

// Newer iOS SDKs declare the Mach-service SPI unavailable. Use a private C
// name bound to the existing symbol, so its SDK availability annotation does
// not merge into this SPI declaration. Keep create's +1 ARC ownership.
extern xpc_connection_t MinisApelinCreateMachService(const char *name,
    dispatch_queue_t targetq, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service") OS_OBJECT_RETURNS_RETAINED;
#endif
