// caustic_curve_fixed.cpp
// Fixed-parameter build of the classic caustic demo (no stdin/argv needed).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iostream>

// Prefer freeglut on Linux; it includes <GL/glut.h> for you.
#include <GL/freeglut.h>

// ===== choose your curve here =====
static constexpr int Q = 200;  // number of points on the curve
static constexpr int P = 37;   // connect i -> (i + P) mod Q
static constexpr int A = 1;    // x(i) = cos(A * 2*pi*i/Q)
static constexpr int B = 1;    // y(i) = sin(B * 2*pi*i/Q)
// ==================================

namespace {
  // Globals used by display()
  int a = A, b = B, p = P, q = Q;
}

void display();
void myinit();

int main(int argc, char* argv[]) {
  char title[128];

  std::snprintf(title, sizeof(title),
                "Caustic  Q=%d  P=%d  A=%d  B=%d", q, p, a, b);

  glutInit(&argc, argv);
  glutInitDisplayMode(GLUT_SINGLE | GLUT_RGB);
  glutInitWindowSize(640, 640);
  glutInitWindowPosition(100, 100);
  glutCreateWindow(title);
  glutDisplayFunc(display);

  myinit();
  glutMainLoop();
  return 0;
}

void display() {
  const float pi = 3.14159265358979323846f;
  const float r  = 1.0f;

  // Precompute points on the generator curve
  float* xy = new float[2 * q];
  int k = 0;
  for (int i = 0; i < q; ++i) {
    float theta = (float)(i * 2) * pi / (float)q;
    xy[k]   = r * std::cos(a * theta);
    xy[k+1] = r * std::sin(b * theta);
    k += 2;
  }

  glClear(GL_COLOR_BUFFER_BIT);

  // Points (BLUE)
  glColor3f(0.0f, 0.0f, 1.0f);
  for (int i = 0; i < q; ++i) {
    glBegin(GL_POINTS);
      glVertex2fv(xy + i * 2);
    glEnd();
  }

  // Boundary polyline (GREEN)
  glColor3f(0.0f, 1.0f, 0.0f);
  for (int i = 0; i < q; ++i) {
    int j = (i + 1) % q;
    glBegin(GL_LINES);
      glVertex2fv(xy + i * 2);
      glVertex2fv(xy + j * 2);
    glEnd();
  }

  // Caustic chords (RED)
  glColor3f(1.0f, 0.0f, 0.0f);
  for (int i = 0; i < q; ++i) {
    int j = (i + p) % q;
    glBegin(GL_LINES);
      glVertex2fv(xy + i * 2);
      glVertex2fv(xy + j * 2);
    glEnd();
  }

  glFlush();
  delete[] xy;
}

void myinit() {
  glClearColor(1.0f, 1.0f, 1.0f, 1.0f); // white background
  glPointSize(5.0f);

  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  // Show a little margin around [-1,1]^2
  gluOrtho2D(-1.1, 1.1, -1.1, 1.1);

  glMatrixMode(GL_MODELVIEW);
}
