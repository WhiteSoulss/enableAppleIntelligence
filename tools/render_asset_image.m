#import <AppKit/AppKit.h>

static BOOL WritePNG(NSImage *image, NSString *path, CGFloat size) {
    NSRect rect = NSMakeRect(0, 0, size, size);
    NSImage *canvas = [[NSImage alloc] initWithSize:rect.size];
    [canvas lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFill(rect);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithFocusedViewRect:rect];
    [canvas unlockFocus];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 5) {
            fprintf(stderr, "usage: %s <bundle-path> <image-name> <output.png> <size>\n", argv[0]);
            return 2;
        }

        NSString *bundlePath = [NSString stringWithUTF8String:argv[1]];
        NSString *imageName = [NSString stringWithUTF8String:argv[2]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[3]];
        CGFloat size = atof(argv[4]);

        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        if (!bundle) {
            fprintf(stderr, "bundle not found: %s\n", argv[1]);
            return 3;
        }
        [bundle load];

        NSImage *image = [bundle imageForResource:imageName];
        if (!image) {
            NSString *resourcePath = [bundle pathForResource:imageName ofType:@"png"];
            if (resourcePath) {
                image = [[NSImage alloc] initWithContentsOfFile:resourcePath];
            }
        }
        if (!image) {
            image = [NSImage imageNamed:imageName];
        }
        if (!image) {
            fprintf(stderr, "image not found: %s in %s\n", argv[2], argv[1]);
            return 4;
        }

        if (!WritePNG(image, outputPath, size)) {
            fprintf(stderr, "write failed: %s\n", argv[3]);
            return 5;
        }

        printf("wrote %s\n", argv[3]);
    }
    return 0;
}
