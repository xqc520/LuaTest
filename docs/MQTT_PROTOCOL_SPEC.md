# MQTT 通讯协议说明

最后更新：2026-03-27

当前项目的实际对接请统一参考：

- `docs/SERVER_API.md`

## 1. 当前项目采用的 Topic 结构

业务 Topic：

```text
sys/{SN}/json/{direction}/{function}
```

OTA Topic：

```text
sys/{SN}/ota/{direction}/{function}
```

## 2. 当前项目已落地的 Topic

- `sys/{SN}/json/up/realTime`
- `sys/{SN}/json/down/cmd`
- `sys/{SN}/json/down/resp`
- `sys/{SN}/json/up/resp`
- `sys/{SN}/ota/down/update`
- `sys/{SN}/ota/up/resport`

## 3. 当前项目的 MQTT 分工

- MQTT1：主服务器，负责控制和上报
- MQTT2：辅助服务器，只负责 `realTime` 上报

也就是说：

- 校时只认 MQTT1
- `SM4` 只认 MQTT1
- 设备命令只认 MQTT1
- OTA 只认 MQTT1

## 4. Payload 说明

当前 `realTime` 的 payload 不是明文 JSON，而是：

1. 原始 485 数据
2. `SM4-CBC`
3. `PKCS7`
4. `HEX`

服务器收到后需要先解密。

## 5. 一句话结论

如果你要对接当前固件，不要再单独参考旧协议稿，直接看：

- `docs/SERVER_API.md`
