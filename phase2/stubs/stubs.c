/*
 * Link-time stubs. Linking against these records the right SONAMEs as NEEDED
 * entries; at runtime the loader binds to the device's real libraries. This
 * avoids having to pull libcutils.so / liblog.so off the device to build.
 *
 * Built one-per-SONAME by phase2/build.sh -- never linked into the product.
 */
#include <stdarg.h>

#ifdef STUB_LOG
int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	(void)prio; (void)tag; (void)fmt;
	return 0;
}
#endif

#ifdef STUB_CUTILS
int property_get(const char *key, char *value, const char *default_value)
{
	(void)key; (void)value; (void)default_value;
	return 0;
}
#endif
