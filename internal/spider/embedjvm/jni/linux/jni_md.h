#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT
#define JNICALL

typedef int jint;
typedef long jlong;
typedef signed char jbyte;

#endif
