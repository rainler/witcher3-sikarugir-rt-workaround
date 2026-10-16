#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <unistd.h>

// Witcher 3 5.01 precompiles a SHARC path-tracing pipeline with PT disabled.
// On the tested M5/macOS 27.2/GPTK 4b2 setup its 64-bit CAS fails compilation.
// Only that inactive PT shader is substituted; ordinary RT pipelines are forwarded.
static IMP original_create;
static id<MTLFunction> inactive_function;
static dispatch_once_t inactive_once;
static char inactive_key;
static char encoder_key;
static NSMutableDictionary<NSString *, NSValue *> *encoder_originals;
// The installer supplies paths for the recipient's account and wrapper.
static NSString *settings_path;
static const char *log_path;


static void record(NSString *message) {
    if (!log_path || !*log_path) return;
    const char *bytes = message.UTF8String;
    size_t length = strlen(bytes);
    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        while (length) {
            ssize_t n = write(fd, bytes, length);
            if (n <= 0) break;
            length -= (size_t)n;
            bytes += n;
        }
        close(fd);
    }
}

static BOOL pathtracing_off(void) {
    NSString *settings = [NSString stringWithContentsOfFile:settings_path encoding:NSUTF8StringEncoding error:nil];
    BOOL disabled = NO;
    for (NSString *line in [settings componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *value = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([value isEqualToString:@"PTEnable=true"]) return NO;
        if ([value isEqualToString:@"PTEnable=false"]) disabled = YES;
    }
    return disabled;
}

static BOOL game_process(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 0; i < argc; ++i) {
        NSString *argument = [NSString stringWithUTF8String:argv[i]];
        if ([argument.lowercaseString containsString:@"witcher3.exe"]) return YES;
    }
    return NO;
}

static NSString *method_key(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@:%s", NSStringFromClass(cls), sel_getName(selector)];
}

static IMP encoder_original(id self, SEL selector) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = encoder_originals[method_key(cls, selector)];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void note_dispatch(id self, SEL selector) {
    if (objc_getAssociatedObject(self, &encoder_key))
        record([NSString stringWithFormat:@"pid=%d INACTIVE_PT_DISPATCH selector=%s\n", getpid(), sel_getName(selector)]);
}

static void encoder_set(id self, SEL selector, id pipeline) {
    objc_setAssociatedObject(self, &encoder_key, objc_getAssociatedObject(pipeline, &inactive_key), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))encoder_original(self, selector))(self, selector, pipeline);
}

static void encoder_dispatch(id self, SEL selector, MTLSize grid, MTLSize group) {
    note_dispatch(self, selector);
    ((void (*)(id, SEL, MTLSize, MTLSize))encoder_original(self, selector))(self, selector, grid, group);
}

static void encoder_indirect3(id self, SEL selector, id buffer, NSUInteger offset, MTLSize group) {
    note_dispatch(self, selector);
    ((void (*)(id, SEL, id, NSUInteger, MTLSize))encoder_original(self, selector))(self, selector, buffer, offset, group);
}

static void encoder_indirect4(id self, SEL selector, MTLGPUAddress address, MTLSize group) {
    note_dispatch(self, selector);
    ((void (*)(id, SEL, MTLGPUAddress, MTLSize))encoder_original(self, selector))(self, selector, address, group);
}

static void encoder_threads4(id self, SEL selector, MTLGPUAddress address) {
    note_dispatch(self, selector);
    ((void (*)(id, SEL, MTLGPUAddress))encoder_original(self, selector))(self, selector, address);
}

static void watch_method(Class cls, SEL selector, IMP replacement) {
    NSString *key = method_key(cls, selector);
    if (encoder_originals[key]) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    if (original == replacement) return;
    encoder_originals[key] = [NSValue valueWithPointer:original];
    class_addMethod(cls, selector, original, method_getTypeEncoding(method));
    method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}

static void watch_encoder(id encoder) {
    Class cls = object_getClass(encoder);
    if (!cls) return;
    watch_method(cls, @selector(setComputePipelineState:), (IMP)encoder_set);
    watch_method(cls, @selector(dispatchThreadgroups:threadsPerThreadgroup:), (IMP)encoder_dispatch);
    watch_method(cls, @selector(dispatchThreads:threadsPerThreadgroup:), (IMP)encoder_dispatch);
    watch_method(cls, @selector(dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:), (IMP)encoder_indirect3);
    watch_method(cls, @selector(dispatchThreadgroupsWithIndirectBuffer:threadsPerThreadgroup:), (IMP)encoder_indirect4);
    watch_method(cls, @selector(dispatchThreadsWithIndirectBuffer:), (IMP)encoder_threads4);
    record([NSString stringWithFormat:@"pid=%d dispatch monitoring class=%@\n", getpid(), NSStringFromClass(cls)]);
}

static id create_pipeline(id self, SEL selector, MTLComputePipelineDescriptor *descriptor,
                          MTLPipelineOption options, MTLComputePipelineReflection **reflection,
                          NSError **error) {
    typedef id (*Create)(id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption,
                         MTLComputePipelineReflection **, NSError **);
    NSError *__autoreleasing local_error = nil;
    NSError *__autoreleasing *destination = error ? error : &local_error;
    id result = ((Create)original_create)(self, selector, descriptor, options, reflection, destination);
    NSString *name = descriptor.computeFunction.name ?: @"";
    if (!result && [name hasPrefix:@"PTRGS_Sharc"] &&
        [(*destination).localizedDescription containsString:@"air.atomic.global.cmpxchg.weak.i64"] &&
        pathtracing_off()) {
        dispatch_once(&inactive_once, ^{
            NSError *compile_error = nil;
            MTLCompileOptions *compile_options = [MTLCompileOptions new];
            compile_options.languageVersion = MTLLanguageVersion3_0;
            id<MTLLibrary> library = [(id<MTLDevice>)self newLibraryWithSource:
                @"#include <metal_stdlib>\nusing namespace metal;\nkernel void inactive_pt_sharc() {}\n"
                options:compile_options error:&compile_error];
            inactive_function = [library newFunctionWithName:@"inactive_pt_sharc"];
            if (!inactive_function) record([NSString stringWithFormat:@"pid=%d fallback compile error=%@\n", getpid(), compile_error]);
        });
        if (inactive_function) {
            MTLComputePipelineDescriptor *inactive = [descriptor copy];
            inactive.computeFunction = inactive_function;
            NSError *fallback_error = nil;
            result = ((Create)original_create)(self, selector, inactive, options, reflection, &fallback_error);
            if (result) objc_setAssociatedObject(result, &inactive_key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            *destination = fallback_error;
            record([NSString stringWithFormat:@"pid=%d inactive SHARC fallback success=%d shader=%@ error=%@\n",
                getpid(), result != nil, [name substringToIndex:MIN(name.length, (NSUInteger)64)], fallback_error]);
        }
    } else if (!result || [name containsString:@"RGS"] || [name containsString:@"RayGen"]) {
        record([NSString stringWithFormat:@"pid=%d forwarded pipeline success=%d shader=%@ error=%@\n",
            getpid(), result != nil, [name substringToIndex:MIN(name.length, (NSUInteger)64)], *destination]);
    }
    return result;
}

__attribute__((constructor)) static void activate(void) {
    @autoreleasepool {
        if (!game_process()) return;
        const char *configured_settings = getenv("W3_RT_COMPAT_SETTINGS_PATH");
        log_path = getenv("W3_RT_COMPAT_LOG_PATH");
        if (!configured_settings || !*configured_settings) return;
        settings_path = [NSString stringWithUTF8String:configured_settings];
        if (!pathtracing_off()) {
            record([NSString stringWithFormat:@"pid=%d workaround inactive: Path Tracing is enabled or its setting is missing\n", getpid()]);
            return;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Class cls = object_getClass(device);
        SEL selector = @selector(newComputePipelineStateWithDescriptor:options:reflection:error:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            record([NSString stringWithFormat:@"pid=%d missing pipeline method\n", getpid()]);
            return;
        }
        original_create = method_getImplementation(method);
        class_addMethod(cls, selector, original_create, method_getTypeEncoding(method));
        method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)create_pipeline);
        encoder_originals = [NSMutableDictionary new];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
        watch_encoder(encoder);
        [encoder endEncoding];
        if (@available(macOS 26.0, *)) {
            id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
            id<MTL4CommandBuffer> buffer = [device newCommandBuffer];
            [buffer beginCommandBufferWithAllocator:allocator];
            id<MTL4ComputeCommandEncoder> encoder4 = [buffer computeCommandEncoder];
            watch_encoder(encoder4);
            [encoder4 endEncoding];
            [buffer endCommandBuffer];
        }
        record([NSString stringWithFormat:@"pid=%d active GPU=%@; PT disabled; ordinary RT forwarded\n", getpid(), device.name]);
    }
}
