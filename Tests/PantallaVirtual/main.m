// Crea una segunda pantalla Retina en el Mac de pruebas, que no tiene monitor físico.
// Usa una API privada de macOS, por eso vive aquí y nunca entra en la app que se instala.
// Sigue viva hasta que se cierre el proceso. Con "--principal" pasa a ser la pantalla principal.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static CGVirtualDisplay *display;

static void makePrimary(CGDirectDisplayID displayID) {
    CGDisplayConfigRef config;
    CGBeginDisplayConfiguration(&config);
    CGDirectDisplayID previous = CGMainDisplayID();
    // La principal es la que está en el origen: la anterior debe correrse a un lado.
    CGConfigureDisplayOrigin(config, displayID, 0, 0);
    CGConfigureDisplayOrigin(config, previous, (int32_t)CGDisplayPixelsWide(displayID), 0);
    CGError error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        printf("pantalla principal: error %d, ahora %u, virtual %u\n", error, CGMainDisplayID(), displayID);
        fflush(stdout);
    });
}

static void chooseRetinaMode(CGDirectDisplayID displayID) {
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    CGDisplayModeRef best = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t points = CGDisplayModeGetWidth(mode);
        size_t pixels = CGDisplayModeGetPixelWidth(mode);
        printf("modo %zux%zu puntos, %zu pixeles de ancho\n", points, CGDisplayModeGetHeight(mode), pixels);
        if (pixels == points * 2 && (best == NULL || points > CGDisplayModeGetWidth(best))) {
            best = mode;
        }
    }
    if (best != NULL) {
        CGError error = CGDisplaySetDisplayMode(displayID, best, NULL);
        printf("modo Retina elegido: %zu puntos, error %d\n", CGDisplayModeGetWidth(best), error);
    } else {
        printf("sin modo Retina\n");
    }
    CFRelease(modes);
    fflush(stdout);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
            printf("este macOS no ofrece pantallas virtuales\n");
            return 1;
        }

        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        [descriptor setDispatchQueue:dispatch_get_main_queue()];
        descriptor.name = @"Zas Retina";
        descriptor.maxPixelsWide = 2880;
        descriptor.maxPixelsHigh = 1800;
        descriptor.sizeInMillimeters = CGSizeMake(300, 190);
        descriptor.serialNum = 1;
        descriptor.productID = 0x5A41;
        descriptor.vendorID = 0x5A53;

        display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            printf("no se pudo crear la pantalla virtual\n");
            return 1;
        }

        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[
            [[modeClass alloc] initWithWidth:2880 height:1800 refreshRate:60],
            [[modeClass alloc] initWithWidth:1440 height:900 refreshRate:60],
        ];
        BOOL applied = [display applySettings:settings];
        CGDirectDisplayID displayID = display.displayID;
        printf("pantalla virtual %u, ajustes %d\n", displayID, applied);
        fflush(stdout);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            chooseRetinaMode(displayID);
            if (argc > 1 && strcmp(argv[1], "--principal") == 0) {
                makePrimary(displayID);
            }
        });
        dispatch_main();
    }
}
