/**
 * @file    map_protocol.h
 * @brief   SPP 点云帧的坐标量化和显式小端编码。
 *
 * 上位机协议栅格：201×201，原点索引 100，分辨率 5 cm。
 * 仅依赖标准 C 库，供 MCU 发送路径和主机端到端验证共用。
 */
#ifndef MAP_PROTOCOL_H_
#define MAP_PROTOCOL_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <math.h>

#define MAP_PROTOCOL_SIZE             201
#define MAP_PROTOCOL_ORIGIN           100
#define MAP_PROTOCOL_RES_M            0.05f
#define MAP_PROTOCOL_MAX_POINTS       300u
#define MAP_PROTOCOL_POINTS_TYPE      0x02u
#define MAP_PROTOCOL_RESET_TYPE       0x03u
#define MAP_PROTOCOL_MAX_FRAME_BYTES  (18u + 2u * MAP_PROTOCOL_MAX_POINTS)

/** @brief 同一扫描参考位姿及全局障碍端点的发送快照。 */
typedef struct {
    uint8_t frame_type;
    uint32_t map_generation; /* 仅用于 RAM 队列拒绝复位前帧，不写入协议。 */
    uint8_t rx;
    uint8_t ry;
    int16_t yaw_mrad;      /* 扫描参考位姿偏航，单位 mrad。 */
    int16_t vy_mm_s;       /* Lateral velocity, slot1 / 横向速度，第1速度槽，mm/s。 */
    int16_t vx_mm_s;       /* Forward velocity, slot2 / 前向速度，第2速度槽，mm/s。 */
    int16_t wz_mrad_s;     /* 车体自旋反馈速度，单位 mrad/s。 */
    uint16_t n;
    uint8_t gx[MAP_PROTOCOL_MAX_POINTS];
    uint8_t gy[MAP_PROTOCOL_MAX_POINTS];
} map_protocol_points_t;

/** @brief 毫秒计数回绕后仍可拒绝复位前扫描；有效时间差须小于半个周期。 */
static inline bool map_protocol_scan_after_reset(uint32_t scan_start_ms, uint32_t reset_ms)
{
    uint32_t elapsed = scan_start_ms - reset_ms;
    return elapsed != 0u && elapsed < UINT32_C(0x80000000);
}

/** @brief 有限物理量缩放后四舍五入，超出 int16_t 时饱和；非有限值编码为零。 */
static inline int16_t map_protocol_quantize_signed(float value, float scale)
{
    float scaled;
    if (!isfinite(value) || !isfinite(scale)) {
        return 0;
    }
    scaled = value * scale;
    if (scaled >= 32767.0f) return INT16_MAX;
    if (scaled <= -32768.0f) return INT16_MIN;
    return (int16_t)lroundf(scaled);
}

/** @brief 将世界坐标米数转换为协议栅格；越界或非有限坐标返回 false。 */
static inline bool map_protocol_world_to_grid(float x_m, float y_m,
                                           uint8_t *gx, uint8_t *gy)
{
    float ix;
    float iy;
    if (!isfinite(x_m) || !isfinite(y_m) || gx == NULL || gy == NULL) {
        return false;
    }
    ix = floorf(x_m / MAP_PROTOCOL_RES_M) + MAP_PROTOCOL_ORIGIN;
    /* Index=floor(metres/0.05)+100; floor(-0.01/0.05)=-1, not0.
     * 每格5cm，原点索引100；负数向下取整，不能改成强转截零，否则地图左右不对称。 */
    iy = floorf(y_m / MAP_PROTOCOL_RES_M) + MAP_PROTOCOL_ORIGIN;
    if (ix < 0.0f || ix >= MAP_PROTOCOL_SIZE ||
        iy < 0.0f || iy >= MAP_PROTOCOL_SIZE) {
        return false;
    }
    *gx = (uint8_t)ix;
    *gy = (uint8_t)iy;
    return true;
}

static inline void map_protocol_put_u16(uint8_t *output, size_t *offset, uint16_t value)
{
    output[(*offset)++] = (uint8_t)value;
    output[(*offset)++] = (uint8_t)(value >> 8);
}

/**
 * @brief 编码点云或复位帧，返回实际字节数；非法消息/容量不足返回零。
 *
 * Body axes follow kinematics:Vx forward,Vy left,Wz counter-clockwise.
 * 车体速度命名统一为Vx前、Vy左、Wz逆时针，地图显示坐标轴保持原约定。
 * 点云载荷为 TYPE/rx/ry/yaw/Vy/Vx/Wz/N/交错端点，共 13+2*N 字节。
 * Slots are unchanged in both directions / 上下发均横向槽在前、前向槽在后，字节位置不变。
 * 输出包含帧头、长度和 XOR 校验；不直接复制结构体或依赖字节对齐。
 */
static inline size_t map_protocol_encode(const map_protocol_points_t *message,
                                         uint8_t *output, size_t capacity)
{
    size_t offset = 0;
    uint16_t payload;
    uint8_t checksum = 0;
    if (message == NULL || output == NULL) return 0;
    if (message->frame_type == MAP_PROTOCOL_RESET_TYPE) {
        payload = 1u;
    } else if (message->frame_type == MAP_PROTOCOL_POINTS_TYPE &&
               message->n <= MAP_PROTOCOL_MAX_POINTS &&
               message->rx < MAP_PROTOCOL_SIZE && message->ry < MAP_PROTOCOL_SIZE) {
        payload = (uint16_t)(13u + 2u * message->n);
        for (uint16_t i = 0; i < message->n; ++i) {
            if (message->gx[i] >= MAP_PROTOCOL_SIZE ||
                message->gy[i] >= MAP_PROTOCOL_SIZE) return 0;
        }
    } else {
        return 0;
    }
    if (capacity < (size_t)payload + 5u) return 0;
    output[offset++] = 0xAAu;
    /* Wire format: AA55, length_L/H, payload, XOR(length+payload).
     * 帧长度仅指载荷；点云总长18+2*N，最多618字节；清图帧共6字节。 */
    output[offset++] = 0x55u;
    map_protocol_put_u16(output, &offset, payload);
    output[offset++] = message->frame_type;
    if (message->frame_type == MAP_PROTOCOL_POINTS_TYPE) {
        output[offset++] = message->rx;
        output[offset++] = message->ry;
        map_protocol_put_u16(output, &offset, (uint16_t)message->yaw_mrad);
        map_protocol_put_u16(output, &offset, (uint16_t)message->vy_mm_s);
        map_protocol_put_u16(output, &offset, (uint16_t)message->vx_mm_s);
        map_protocol_put_u16(output, &offset, (uint16_t)message->wz_mrad_s);
        map_protocol_put_u16(output, &offset, message->n);
        for (uint16_t i = 0; i < message->n; ++i) {
            output[offset++] = message->gx[i];
            output[offset++] = message->gy[i];
        }
    }
    for (size_t i = 2; i < offset; ++i) checksum ^= output[i];
    /* Header bytes are excluded; all multi-byte fields were emitted low byte first.
     * XOR不含AA55帧头；多字节字段均显式小端，不依赖结构体内存对齐。 */
    output[offset++] = checksum;
    return offset;
}

#endif /* MAP_PROTOCOL_H_ */
