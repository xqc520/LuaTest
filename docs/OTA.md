# OTA 说明

最后更新：2026-03-27

当前项目 OTA 只保留一种方式：

```text
sys/{SN}/ota/down/update
```

设备回包：

```text
sys/{SN}/ota/up/resport
```

说明：

- OTA 只认 MQTT1
- MQTT2 不参与 OTA
- 实际下发格式、回包字段和示例，请统一参考：
  - `docs/SERVER_API.md`
