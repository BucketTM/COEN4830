// qt6_marquette.cpp - Qt6 Hello Marquette
// Marquette University
// Arthur Kear
// 13-Oct-2025
//
// To build: 
//     $ qmake6 -project
//     $ echo “QT += gui widgets” >> qt6_marquette.pro
//     $ qmake6 qt6_marquette.pro
//     $ make
//     $ ./qt6_marquette
//
// See: https://vitux.com/compiling-your-first-qt-program-in-ubuntu/
//
// For Ubuntu 24.04 it is necessary to install these packages:
//   build_essential qtcreator qt6-base qt6-base-doc qt6-base-doc-html 
//   qt6-base-examples libclang-dev
//

#include <QApplication>
#include <QLabel>
#include <QWidget>

int main(int argc, char* argv[])
{
    QApplication app(argc, argv);
    QLabel hello("<center>Hello Marquette!</center>");
    hello.setWindowTitle("Hello Marquette QT");
    hello.resize(400,400);
    hello.show();
    return app.exec();
}
