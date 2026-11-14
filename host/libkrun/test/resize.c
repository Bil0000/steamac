// Display resize harness: boots the steamac guest like the launcher (kernel + initramfs,
// disks, gvproxy virtio-net, Venus GPU, one display, hvc0 + fx.progress console ports) but
// without a window or input devices, and takes commands on a FIFO while the VM runs:
//
//   resize W H WMM HMM   krun_display_resize(ctx, 0, W, H, WMM, HMM)
//   mode W H WMM HMM HZ  krun_display_set_mode(ctx, 0, W, H, WMM, HMM, HZ)
//   dump PATH            write the last presented frame as PNG
//
// The display backend logs every configure_scanout (scanout and display size) on stderr.
// Run by resize-test.sh; libkrun exits the process when the guest powers off.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#include <libkrun.h>
#include <libkrun_display.h>

static double start_time;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%8.3f] ", now() - start_time);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void die(const char *what, long r)
{
    say("%s failed: %ld", what, r);
    exit(1);
}

#define KRUN(call)                                                                                 \
    do {                                                                                           \
        int32_t r_ = (call);                                                                       \
        if (r_ < 0)                                                                                \
            die(#call, r_);                                                                        \
    } while (0)

// --- display backend: one scanout, double buffered (alloc_frame hands out the back buffer,
//     present_frame makes it the front one)
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *bufs[2];
static uint32_t width, height, format;
static int front;
static int have_frame;
static unsigned long presents;

static int32_t disp_create(void **instance, const void *userdata, const void *reserved)
{
    (void)userdata;
    (void)reserved;
    *instance = NULL;
    return 0;
}

static int32_t disp_configure(void *instance, uint32_t id, uint32_t dw, uint32_t dh, uint32_t w,
                              uint32_t h, uint32_t fmt)
{
    (void)instance;
    if (id != 0)
        return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    pthread_mutex_lock(&lock);
    if (w != width || h != height) {
        for (int i = 0; i < 2; i++) {
            free(bufs[i]);
            bufs[i] = calloc((size_t)w * h, 4);
        }
        have_frame = 0;
    }
    width = w;
    height = h;
    format = fmt;
    pthread_mutex_unlock(&lock);
    say("configure_scanout: scanout %ux%u format %u, display %ux%u", w, h, fmt, dw, dh);
    return 0;
}

static int32_t disp_disable(void *instance, uint32_t id)
{
    (void)instance;
    say("disable_scanout %u", id);
    return 0;
}

static int32_t disp_alloc(void *instance, uint32_t id, uint8_t **buffer, size_t *size)
{
    (void)instance;
    if (id != 0)
        return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    pthread_mutex_lock(&lock);
    *buffer = bufs[!front];
    *size = (size_t)width * height * 4;
    pthread_mutex_unlock(&lock);
    return 0;
}

static int32_t disp_present(void *instance, uint32_t id, uint32_t frame_id,
                            const struct krun_rect *damage)
{
    (void)instance;
    (void)frame_id;
    (void)damage;
    if (id != 0)
        return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    pthread_mutex_lock(&lock);
    front = !front;
    have_frame = 1;
    presents++;
    pthread_mutex_unlock(&lock);
    return 0;
}

// Byte offsets of R, G, B in a pixel; virtio-gpu format names give the memory byte order.
static int rgb_offsets(uint32_t fmt, int off[3])
{
    switch (fmt) {
    case KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM:
    case KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM:
        off[0] = 2, off[1] = 1, off[2] = 0;
        return 0;
    case KRUN_DISPLAY_FORMAT_A8R8G8B8_UNORM:
    case KRUN_DISPLAY_FORMAT_X8R8G8B8_UNORM:
        off[0] = 1, off[1] = 2, off[2] = 3;
        return 0;
    case KRUN_DISPLAY_FORMAT_R8G8B8A8_UNORM:
    case KRUN_DISPLAY_FORMAT_R8G8B8X8_UNORM:
        off[0] = 0, off[1] = 1, off[2] = 2;
        return 0;
    case KRUN_DISPLAY_FORMAT_X8B8G8R8_UNORM:
    case KRUN_DISPLAY_FORMAT_A8B8G8R8_UNORM:
        off[0] = 3, off[1] = 2, off[2] = 1;
        return 0;
    }
    return -1;
}

static void dump(const char *path)
{
    pthread_mutex_lock(&lock);
    uint32_t w = width, h = height;
    int off[3];
    if (!have_frame || rgb_offsets(format, off) < 0) {
        pthread_mutex_unlock(&lock);
        say("dump %s: no frame (format %u)", path, format);
        return;
    }
    uint8_t *rgbx = malloc((size_t)w * h * 4);
    const uint8_t *src = bufs[front];
    for (size_t i = 0; i < (size_t)w * h; i++) {
        rgbx[i * 4 + 0] = src[i * 4 + off[0]];
        rgbx[i * 4 + 1] = src[i * 4 + off[1]];
        rgbx[i * 4 + 2] = src[i * 4 + off[2]];
        rgbx[i * 4 + 3] = 0xff;
    }
    unsigned long n = presents;
    pthread_mutex_unlock(&lock);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(rgbx, w, h, 8, (size_t)w * 4, cs,
                                            (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path,
                                                           (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int ok = dst != NULL;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url);
    CGImageRelease(img);
    CGContextRelease(cg);
    CGColorSpaceRelease(cs);
    free(rgbx);
    say("dump %s: %ux%u frame #%lu%s", path, w, h, n, ok ? "" : " FAILED");
}

// --- control FIFO
static uint32_t ctx;

static void *control_thread(void *arg)
{
    const char *fifo = arg;
    // O_RDWR: never sees EOF when a writer closes.
    FILE *f = fopen(fifo, "r+");
    if (!f) {
        say("cannot open %s: %s", fifo, strerror(errno));
        return NULL;
    }
    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        unsigned w, h, wmm, hmm, hz;
        char path[4000];
        if (sscanf(line, "mode %u %u %u %u %u", &w, &h, &wmm, &hmm, &hz) == 5) {
            int32_t r = krun_display_set_mode(ctx, 0, w, h, (uint16_t)wmm, (uint16_t)hmm, hz);
            say("krun_display_set_mode(%ux%u, %ux%u mm, %u Hz) = %d", w, h, wmm, hmm, hz, r);
        } else if (sscanf(line, "resize %u %u %u %u", &w, &h, &wmm, &hmm) == 4) {
            int32_t r = krun_display_resize(ctx, 0, w, h, (uint16_t)wmm, (uint16_t)hmm);
            say("krun_display_resize(%ux%u, %ux%u mm) = %d", w, h, wmm, hmm, r);
        } else if (sscanf(line, "dump %3999s", path) == 1) {
            dump(path);
        } else {
            say("unknown command: %s", line);
        }
    }
    return NULL;
}

// --- hvc0: a pty whose master is copied to the console log
static void *console_thread(void *arg)
{
    int *fds = arg;
    char buf[4096];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof(buf))) > 0)
        if (write(fds[1], buf, (size_t)n) != n)
            break;
    return NULL;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: resize --kernel IMAGE --initrd CPIO --disk PATH[:ro]... --net SOCK\n"
            "              --console LOG --control FIFO [--cmdline STR] [--size WxH] [--mm WxH]\n"
            "              [--cpus N] [--mem MiB] [--shm-mib MiB]\n");
    exit(2);
}

int main(int argc, char **argv)
{
    start_time = now();
    const char *kernel = NULL, *initrd = NULL, *net = NULL, *console = NULL, *control = NULL;
    const char *cmdline = "console=hvc0 loglevel=4 rootwait";
    const char *disks[8];
    int ndisks = 0;
    unsigned w = 1280, h = 800, wmm = 339, hmm = 212, cpus = 8, mem = 16384, shm = 8192;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v)
            usage();
        i++;
        if (!strcmp(a, "--kernel"))
            kernel = v;
        else if (!strcmp(a, "--initrd"))
            initrd = v;
        else if (!strcmp(a, "--cmdline"))
            cmdline = v;
        else if (!strcmp(a, "--disk") && ndisks < 8)
            disks[ndisks++] = v;
        else if (!strcmp(a, "--net"))
            net = v;
        else if (!strcmp(a, "--console"))
            console = v;
        else if (!strcmp(a, "--control"))
            control = v;
        else if (!strcmp(a, "--size") && sscanf(v, "%ux%u", &w, &h) == 2)
            ;
        else if (!strcmp(a, "--mm") && sscanf(v, "%ux%u", &wmm, &hmm) == 2)
            ;
        else if (!strcmp(a, "--cpus"))
            cpus = (unsigned)atoi(v);
        else if (!strcmp(a, "--mem"))
            mem = (unsigned)atoi(v);
        else if (!strcmp(a, "--shm-mib"))
            shm = (unsigned)atoi(v);
        else
            usage();
    }
    if (!kernel || !initrd || !ndisks || !net || !console || !control)
        usage();

    KRUN(krun_init_log(KRUN_LOG_TARGET_DEFAULT, KRUN_LOG_LEVEL_WARN, KRUN_LOG_STYLE_AUTO, 0));
    int32_t c = krun_create_ctx();
    if (c < 0)
        die("krun_create_ctx", c);
    ctx = (uint32_t)c;
    KRUN(krun_set_vm_config(ctx, (uint8_t)cpus, mem));
    KRUN(krun_disable_implicit_vsock(ctx));
    KRUN(krun_disable_implicit_console(ctx));

    int con = krun_add_virtio_console_multiport(ctx);
    if (con < 0)
        die("krun_add_virtio_console_multiport", con);
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0)
        die("openpty", -errno);
    static int console_fds[2];
    console_fds[0] = master;
    console_fds[1] = open(console, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (console_fds[1] < 0)
        die("open console log", -errno);
    pthread_t t;
    pthread_create(&t, NULL, console_thread, console_fds);
    KRUN(krun_add_console_port_tty(ctx, (uint32_t)con, "", slave));
    // The guest's progress agent writes boot progress here; nothing reads it but the sink.
    int progress_in[2];
    if (pipe(progress_in) < 0)
        die("pipe", -errno);
    KRUN(krun_add_console_port_inout(ctx, (uint32_t)con, "fx.progress", progress_in[0],
                                     open("/dev/null", O_WRONLY)));

    KRUN(krun_set_kernel(ctx, kernel, KRUN_KERNEL_FORMAT_RAW, initrd, cmdline));
    for (int i = 0; i < ndisks; i++) {
        char path[4096], id[4] = {'v', 'd', (char)('a' + i), 0};
        snprintf(path, sizeof(path), "%s", disks[i]);
        size_t len = strlen(path);
        bool ro = len > 3 && !strcmp(path + len - 3, ":ro");
        if (ro)
            path[len - 3] = 0;
        KRUN(krun_add_disk2(ctx, id, path, KRUN_DISK_FORMAT_RAW, ro));
    }

    KRUN(krun_set_gpu_options2(ctx, VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL,
                               (uint64_t)shm << 20));
    KRUN(krun_add_display(ctx, w, h));
    KRUN(krun_display_set_physical_size(ctx, 0, (uint16_t)wmm, (uint16_t)hmm));
    struct krun_display_backend display = {
        .features = KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER,
        .create = disp_create,
        .vtable.basic_framebuffer = {
            .disable_scanout = disp_disable,
            .configure_scanout = disp_configure,
            .alloc_frame = disp_alloc,
            .present_frame = disp_present,
        },
    };
    KRUN(krun_set_display_backend(ctx, &display, sizeof(display)));

    uint8_t mac[6] = {0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee}; // gvproxy's static lease
    KRUN(krun_add_net_unixgram(ctx, net, -1, mac, COMPAT_NET_FEATURES, NET_FLAG_VFKIT));

    pthread_create(&t, NULL, control_thread, (void *)control);
    say("booting: display %ux%u, %ux%u mm", w, h, wmm, hmm);
    int32_t r = krun_start_enter(ctx);
    die("krun_start_enter", r);
}
