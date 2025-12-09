// julia.cu - CUDA code to generate a Julia set image
//
// Problem 10 – Julia set:
// Generate a fractal image from the recursive equation
//    Z_{n+1} = Z_n^3 + C   where C is a complex constant.
//
// This code is adapted from the Mandelbrot / Z^4 sample provided.
// It uses a fixed complex constant C and takes each pixel as Z_0.
//
// Compile (on class server):
//   nvcc julia.cu -g -D SHOW_X -o julia -lX11 -lgomp -lm

#include <stdio.h>
#include <unistd.h>
#include <err.h>
#include <stdint.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <omp.h>

#include <cuda_runtime.h>

// image / grid parameters (can be overridden via command line)
static int dim = 512;
static int n = 512;
static int m = 512;
static int max_iter = 100;

static uint32_t *colors;
uint32_t *dev_colors;

// ---- X11 stuff (for interactive display) ----------------------
#ifdef SHOW_X
static Display *dpy;
static XImage *bitmap;
static Window win;
static Atom wmDeleteMessage;
static GC gc;

static void exit_x11(void){
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
}

static void init_x11(){
    dpy = XOpenDisplay(NULL);
    if (!dpy) exit(0);

    unsigned long white = WhitePixel(dpy,DefaultScreen(dpy));
    unsigned long black = BlackPixel(dpy,DefaultScreen(dpy));

    win = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy),
                              0, 0, dim, dim, 0, black, white);

    XSelectInput(dpy, win, StructureNotifyMask);
    XMapWindow(dpy, win);

    while (1){
        XEvent e;
        XNextEvent(dpy, &e);
        if (e.type == MapNotify) break;
    }

    XTextProperty tp;
    char name[128] = "Julia Set (Z^3 + C)";
    char *nptr = name;
    Status st = XStringListToTextProperty(&nptr, 1, &tp);
    if (st) XSetWMName(dpy, win, &tp);

    XFlush(dpy);
    int depth = DefaultDepth(dpy, DefaultScreen(dpy));
    Visual *visual = DefaultVisual(dpy, DefaultScreen(dpy));

    bitmap = XCreateImage(dpy, visual, depth, ZPixmap, 0,
                          (char*) malloc(dim * dim * 32),
                          dim, dim, 32, 0);

    gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, black);

    XSelectInput(dpy, win,
                 ExposureMask | KeyPressMask | StructureNotifyMask);

    wmDeleteMessage = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDeleteMessage, 1);
}
#endif
// --------------------------------------------------------------

// create a color table
void init_colours(void) {
    float freq = 6.3f / max_iter;
    for (int i = 0; i < max_iter; i++){
        unsigned char r = sinf(freq * i + 1) * 127 + 128;
        unsigned char g = sinf(freq * i + 3) * 127 + 128;
        unsigned char b = sinf(freq * i + 5) * 127 + 128;
        colors[i] = b + 256 * g + 256 * 256 * r;
    }
    colors[max_iter] = 0;   // inside the set -> black
}

void checkErr(cudaError_t err, const char* msg){
    if (err != cudaSuccess){
        fprintf(stderr, "%s (error code %d: '%s')\n",
                msg, err, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

// -----------------------------------------------------------------
// Device code: Julia recursion for Z_{n+1} = Z_n^3 + C
// -----------------------------------------------------------------

// fixed complex constant C = C_RE + i*C_IM (Julia parameter)
__device__ __constant__ double C_RE = -0.8;
__device__ __constant__ double C_IM = 0.156;

/* For a starting point z0 = zr + i*zi, iterate
   Z_{n+1} = Z_n^3 + C
   Stop when |Z_n|^2 > 16 or after max_iter iterations.
   Return the iteration count (used to pick a color). */
__device__ uint32_t julia_double(double zr, double zi, int max_iter) {
    uint32_t i;

    for (i = 0; i < (uint32_t)max_iter; i++) {

        // compute z^3 = (zr + i zi)^3
        // real:  zr^3 - 3*zr*zi^2
        // imag:  3*zr^2*zi - zi^3
        double zr2 = zr * zr;
        double zi2 = zi * zi;

        double new_zr = zr2 * zr - 3.0 * zr * zi2 + C_RE;
        double new_zi = 3.0 * zr2 * zi - zi2 * zi + C_IM;

        zr = new_zr;
        zi = new_zi;

        if (zr * zr + zi * zi > 16.0) break;
    }

    return i;
}

/* Each thread evaluates a set of pixels.
   For pixel (x,y), map to complex plane, use as z0, and
   store the color based on julia_double(). */
__global__ void julia_kernel(uint32_t *counts,
                             double xmin, double ymin,
                             double step, int max_iter,
                             int dim, uint32_t *colors) {

    int pix_per_thread = dim * dim / (gridDim.x * blockDim.x);
    int tId = blockDim.x * blockIdx.x + threadIdx.x;
    int offset = pix_per_thread * tId;

    for (int i = offset; i < offset + pix_per_thread; i++){
        int x = i % dim;
        int y = i / dim;
        double zr0 = xmin + x * step;
        double zi0 = ymin + y * step;
        counts[y * dim + x] =
            colors[julia_double(zr0, zi0, max_iter)];
    }

    // handle remaining pixels if dim*dim is not divisible
    if (gridDim.x * blockDim.x * pix_per_thread < dim * dim
        && tId < (dim * dim) - (blockDim.x * gridDim.x)) {

        int i = blockDim.x * gridDim.x * pix_per_thread + tId;
        int x = i % dim;
        int y = i / dim;
        double zr0 = xmin + x * step;
        double zi0 = ymin + y * step;
        counts[y * dim + x] =
            colors[julia_double(zr0, zi0, max_iter)];
    }
}

/* Compute the image for a given center and scale. */
static void display_double(double xcen, double ycen, double scale,
                           uint32_t *dev_counts, uint32_t *colors) {

    double xmin = xcen - (scale/2.0);
    double ymin = ycen - (scale/2.0);
    double step = scale / dim;

    cudaError_t err = cudaSuccess;

#ifdef BENCHMARK
    double start = omp_get_wtime();
#endif

    julia_kernel<<<n, m>>>(dev_counts, xmin, ymin,
                           step, max_iter, dim, colors);
    err = cudaGetLastError();
    checkErr(err, "Failed to launch kernel");

#ifdef SHOW_X
    err = cudaMemcpy(bitmap->data, dev_counts,
                     dim * dim * sizeof(uint32_t),
                     cudaMemcpyDeviceToHost);
#else
    void *data = malloc(dim * dim * sizeof(uint32_t));
    err = cudaMemcpy(data, dev_counts,
                     dim * dim * sizeof(uint32_t),
                     cudaMemcpyDeviceToHost);
#endif
    checkErr(err, "Failed to copy dev_counts back");

#ifdef BENCHMARK
    double stop = omp_get_wtime();
    printf("Blocks: %d  Threads/Block: %d  Size:%dx%d  Depth:%d  Time:%f\n",
           n, m, dim, dim, max_iter, stop - start);
#endif

#ifdef SHOW_X
    XPutImage(dpy, win, gc, bitmap,
              0, 0, 0, 0,
              dim, dim);
    XFlush(dpy);
#endif
}

int main(int argc, char** argv){
    cudaError_t err = cudaSuccess;

    if (argc >= 2) n        = atoi(argv[1]);
    if (argc >= 3) m        = atoi(argv[2]);
    if (argc >= 4) dim      = atoi(argv[3]);
    if (argc >= 5) max_iter = atoi(argv[4]);

    size_t color_size = (max_iter + 1) * sizeof(uint32_t);
    colors = (uint32_t *) malloc(color_size);
    cudaMalloc((void**)&dev_colors, color_size);

    // Julia view parameters (can be changed to explore)
    double xcen  = 0.0;
    double ycen  = 0.0;
    double scale = 3.0;

#ifdef SHOW_X
    init_x11();
#endif
    init_colours();
    cudaMemcpy(dev_colors, colors, color_size, cudaMemcpyHostToDevice);
    free(colors);

    uint32_t *dev_counts = NULL;
    size_t img_size = dim * dim * sizeof(uint32_t);
    err = cudaMalloc(&dev_counts, img_size);
    checkErr(err, "Failed to allocate dev_counts");

    display_double(xcen, ycen, scale, dev_counts, dev_colors);

#ifdef SHOW_X
    // simple interactive loop: wasd + qe + x to quit
    while(1) {
        XEvent event;
        KeySym key;
        char text[255];

        XNextEvent(dpy, &event);
        while (XPending(dpy) > 0)
            XNextEvent(dpy, &event);

        if ((event.type == Expose) && !event.xexpose.count){
            XPutImage(dpy, win, gc, bitmap,
                      0, 0, 0, 0,
                      dim, dim);
        }

        if ((event.type == KeyPress) &&
            XLookupString(&event.xkey, text, 255, &key, 0) == 1) {

            if (text[0] == 'x') break;              // exit
            if (text[0] == 'a'){ xcen -= 20*scale/dim; }
            if (text[0] == 'd'){ xcen += 20*scale/dim; }
            if (text[0] == 'w'){ ycen -= 20*scale/dim; }
            if (text[0] == 's'){ ycen += 20*scale/dim; }
            if (text[0] == 'q'){ scale *= 1.25; }
            if (text[0] == 'e'){ scale *= 0.80; }

            display_double(xcen, ycen, scale, dev_counts, dev_colors);
        }

        if ((event.type == ClientMessage) &&
            ((Atom) event.xclient.data.l[0] == wmDeleteMessage))
            break;
    }

    exit_x11();
#endif

    cudaFree(dev_counts);
    cudaFree(dev_colors);
    return 0;
}
