/*
 * smcfan — Apple Silicon SMC 风扇读写工具（fanctl 项目核心）
 * 通过 AppleSMC IOKit 用户客户端读写风扇寄存器，与 Macs Fan Control/Stats 同通道。
 * 关键键位（M 系芯片）：
 *   FNum (ui8 ) 风扇数量
 *   F%dAc (flt) 实际转速     F%dTg (flt) 目标转速
 *   F%dMn (flt) 最低转速     F%dMx (flt) 最高转速
 *   F%dMd (ui8) 模式 0=系统自动 1=手动
 * 用法:
 *   smcfan probe            列出所有风扇状态
 *   smcfan set <rpm>        全部风扇手动定速（写 Md=1 + Tg）
 *   smcfan auto             全部风扇交还系统自动（写 Md=0）
 *   smcfan get <key>        读任意键（调试用）
 * 写操作需要 root。
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC     2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_KEYINFO 9

typedef unsigned char SMCBytes_t[32];

typedef struct { char major; char minor; char build; char reserved[1]; unsigned short release; } SMCKeyData_vers_t;
typedef struct { unsigned short version; unsigned short length; unsigned int cpuPLimit; unsigned int gpuPLimit; unsigned int memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { unsigned int dataSize; unsigned int dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    unsigned int key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result; char status; char data8;
    unsigned int data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

typedef struct { char key[5]; unsigned int dataSize; char dataType[5]; SMCBytes_t bytes; } SMCVal_t;

static io_connect_t g_conn = 0;

static unsigned int str_to_fourcc(const char *s) {
    return ((unsigned int)s[0] << 24) | ((unsigned int)s[1] << 16) | ((unsigned int)s[2] << 8) | (unsigned int)s[3];
}
static void fourcc_to_str(unsigned int v, char *out) {
    out[0] = (v >> 24) & 0xff; out[1] = (v >> 16) & 0xff; out[2] = (v >> 8) & 0xff; out[3] = v & 0xff; out[4] = 0;
}

static kern_return_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "error: AppleSMC service not found\n"); return kIOReturnError; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return kr;
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outsize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outsize);
}

static kern_return_t smc_read(const char *key, SMCVal_t *val) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out)); memset(val, 0, sizeof(*val));
    strncpy(val->key, key, 4); val->key[4] = 0;
    in.key = str_to_fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess) return kr;
    if (out.result != 0) return kIOReturnNotFound;
    val->dataSize = out.keyInfo.dataSize;
    fourcc_to_str(out.keyInfo.dataType, val->dataType);
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess) return kr;
    if (out.result != 0) return kIOReturnNotFound;
    memcpy(val->bytes, out.bytes, sizeof(out.bytes));
    return kIOReturnSuccess;
}

static kern_return_t smc_write(const char *key, const unsigned char *bytes, unsigned int size) {
    SMCKeyData_t in, out;
    SMCVal_t cur;
    kern_return_t kr = smc_read(key, &cur);           /* 先读 keyInfo 校验键存在与长度 */
    if (kr != kIOReturnSuccess) return kr;
    if (cur.dataSize != size) { fprintf(stderr, "error: %s size mismatch (key=%u given=%u)\n", key, cur.dataSize, size); return kIOReturnBadArgument; }
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = str_to_fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess) return kr;
    if (out.result != 0) { fprintf(stderr, "error: SMC write %s result=%d\n", key, out.result); return kIOReturnError; }
    return kIOReturnSuccess;
}

static float val_as_float(SMCVal_t *v) {
    if (strcmp(v->dataType, "flt ") == 0 && v->dataSize == 4) { float f; memcpy(&f, v->bytes, 4); return f; }
    if (strcmp(v->dataType, "ui8 ") == 0) return (float)v->bytes[0];
    if (strcmp(v->dataType, "ui16") == 0) return (float)((v->bytes[0] << 8) | v->bytes[1]);
    return -1.0f;
}

static int fan_count(void) {
    SMCVal_t v;
    if (smc_read("FNum", &v) != kIOReturnSuccess) return 0;
    return v.bytes[0];
}

static int cmd_probe(void) {
    int n = fan_count();
    printf("fans=%d\n", n);
    for (int i = 0; i < n; i++) {
        char k[5]; SMCVal_t v; float ac=-1, tg=-1, mn=-1, mx=-1; int md=-1;
        snprintf(k, 5, "F%dAc", i); if (smc_read(k, &v) == kIOReturnSuccess) ac = val_as_float(&v);
        snprintf(k, 5, "F%dTg", i); if (smc_read(k, &v) == kIOReturnSuccess) tg = val_as_float(&v);
        snprintf(k, 5, "F%dMn", i); if (smc_read(k, &v) == kIOReturnSuccess) mn = val_as_float(&v);
        snprintf(k, 5, "F%dMx", i); if (smc_read(k, &v) == kIOReturnSuccess) mx = val_as_float(&v);
        snprintf(k, 5, "F%dMd", i); if (smc_read(k, &v) == kIOReturnSuccess) md = v.bytes[0];
        printf("fan%d actual=%.0f target=%.0f min=%.0f max=%.0f mode=%s\n",
               i, ac, tg, mn, mx, md == 1 ? "manual" : md == 0 ? "auto" : "?");
    }
    return 0;
}

static int cmd_set(float rpm) {
    int n = fan_count();
    if (n <= 0) { fprintf(stderr, "error: no fans\n"); return 1; }
    for (int i = 0; i < n; i++) {
        char k[5]; SMCVal_t v; float mn = 0, mx = 0;
        snprintf(k, 5, "F%dMn", i); if (smc_read(k, &v) == kIOReturnSuccess) mn = val_as_float(&v);
        snprintf(k, 5, "F%dMx", i); if (smc_read(k, &v) == kIOReturnSuccess) mx = val_as_float(&v);
        float target = rpm;
        if (mx > 0 && target > mx) target = mx;      /* 永不超过硬件上限 */
        if (mn > 0 && target < mn) target = mn;      /* 永不低于硬件下限：手动模式没有比自动更低的余地 */
        /* 模式键只在需要改变时写：高频重复写 F%dMd 会把 SMC 顶进保护态
           （读出 3 = 系统接管，此后所有写入被拒）。目标转速键可安全高频写。 */
        snprintf(k, 5, "F%dMd", i);
        int md = -1;
        if (smc_read(k, &v) == kIOReturnSuccess) md = v.bytes[0];
        if (md != 0 && md != 1) { fprintf(stderr, "error: %s=%d (system override)\n", k, md); return 3; }
        if (md != 1) {
            unsigned char one = 1;
            if (smc_write(k, &one, 1) != kIOReturnSuccess) { fprintf(stderr, "error: write %s failed (need root?)\n", k); return 1; }
        }
        snprintf(k, 5, "F%dTg", i);
        if (smc_write(k, (unsigned char *)&target, 4) != kIOReturnSuccess) { fprintf(stderr, "error: write %s failed\n", k); return 1; }
        printf("fan%d -> manual %.0f rpm\n", i, target);
    }
    return 0;
}

static int cmd_auto(void) {
    int n = fan_count();
    int rc = 0;
    for (int i = 0; i < n; i++) {
        char k[5]; unsigned char zero = 0; SMCVal_t v;
        snprintf(k, 5, "F%dMd", i);
        if (smc_read(k, &v) == kIOReturnSuccess && v.bytes[0] == 0) { printf("fan%d already auto\n", i); continue; }
        if (smc_write(k, &zero, 1) != kIOReturnSuccess) { fprintf(stderr, "error: restore %s failed\n", k); rc = 1; }
        else printf("fan%d -> auto\n", i);
    }
    return rc;
}

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: smcfan probe | set <rpm> | auto | get <key>\n"); return 2; }
    if (smc_open() != kIOReturnSuccess) { fprintf(stderr, "error: cannot open AppleSMC\n"); return 1; }
    int rc = 2;
    if (strcmp(argv[1], "probe") == 0) rc = cmd_probe();
    else if (strcmp(argv[1], "set") == 0 && argc == 3) rc = cmd_set((float)atof(argv[2]));
    else if (strcmp(argv[1], "auto") == 0) rc = cmd_auto();
    else if (strcmp(argv[1], "poke") == 0 && argc == 4) {   /* 诊断用：写任意键 */
        SMCVal_t cur;
        if (smc_read(argv[2], &cur) != kIOReturnSuccess) { fprintf(stderr, "read %s failed\n", argv[2]); rc = 1; }
        else {
            double v = atof(argv[3]);
            unsigned char buf[8] = {0};
            unsigned int sz = cur.dataSize;
            if (strcmp(cur.dataType, "flt ") == 0) { float f = (float)v; memcpy(buf, &f, 4); sz = 4; }
            else if (sz == 1) buf[0] = (unsigned char)v;
            else if (sz == 2) { buf[0] = ((int)v >> 8) & 0xff; buf[1] = (int)v & 0xff; }
            rc = smc_write(argv[2], buf, sz) == kIOReturnSuccess ? 0 : 1;
            printf("poke %s = %g -> %s\n", argv[2], v, rc == 0 ? "ok" : "FAILED");
        }
    }
    else if (strcmp(argv[1], "get") == 0 && argc == 3) {
        SMCVal_t v;
        if (smc_read(argv[2], &v) == kIOReturnSuccess) {
            printf("%s type=%s size=%u value=%.1f raw=", argv[2], v.dataType, v.dataSize, val_as_float(&v));
            for (unsigned i = 0; i < v.dataSize; i++) printf("%02x", v.bytes[i]);
            printf("\n"); rc = 0;
        } else { fprintf(stderr, "error: read %s failed\n", argv[2]); rc = 1; }
    }
    IOServiceClose(g_conn);
    return rc;
}
