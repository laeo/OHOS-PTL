/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef PC_PTL_BT_VENDOR_LINUX_H
#define PC_PTL_BT_VENDOR_LINUX_H

/*
 * Self-contained mirror of the BT vendor-HAL ABI that the OHOS HCI HDI expects.
 *
 * It must stay binary compatible with
 *   drivers/peripheral/bluetooth/hci/hdi_service/implement/ohos_bt_vendor_lib.h
 * which the host does dlopen()s this .so against.  We deliberately do NOT
 * include that header (it is a C++ header, we build this as plain C) and we do
 * not depend on kernel UAPI headers being present in the musl sysroot, so the
 * few constants/structs we need are spelled out here.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* hci_channels_t - index into the fd array returned by BT_OP_HCI_CHANNEL_OPEN */
typedef enum {
    HCI_CMD = 0,
    HCI_EVT,
    HCI_ACL_OUT,
    HCI_ACL_IN,
    HCI_MAX_CHANNEL
} hci_channels_t;

typedef enum {
    BTC_OP_RESULT_SUCCESS,
    BTC_OP_RESULT_FAIL,
} BtOpResultT;

/* BtOpcodeT - must match the HDI enum exactly */
typedef enum {
    BT_OP_POWER_ON = 0,
    BT_OP_POWER_OFF,
    BT_OP_HCI_CHANNEL_OPEN,
    BT_OP_HCI_CHANNEL_CLOSE,
    BT_OP_INIT,
    BT_OP_GET_LPM_TIMER,
    BT_OP_LPM_ENABLE,
    BT_OP_LPM_DISABLE,
    BT_OP_WAKEUP_LOCK,
    BT_OP_WAKEUP_UNLOCK,
    BT_OP_EVENT_CALLBACK,
    BT_OP_MAX
} BtOpcodeT;

typedef void (*InitCallback)(BtOpResultT result);
typedef void *(*MallocCallback)(int size);
typedef void (*FreeCallback)(void *buf);
typedef size_t (*CmdXmitCallback)(uint16_t opcode, void *pBuf);

typedef struct {
    size_t size;
    InitCallback initCb;
    MallocCallback alloc;
    FreeCallback dealloc;
    CmdXmitCallback xmitCb;
} BtVendorCallbacksT;

typedef struct {
    size_t size;
    int (*init)(const BtVendorCallbacksT *pCb, unsigned char *localBdaddr);
    int (*op)(BtOpcodeT opcode, void *param);
    void (*close)(void);
} BtVendorInterfaceT;

/*
 * Linux HCI socket constants.
 *
 * Spelled out because the musl sysroot used for the standalone build does not
 * ship <linux/bluetooth.h>.  Values verified against
 *   kernel/linux/linux-7.2/include/uapi/linux/bluetooth.h
 *   kernel/linux/linux-7.2/include/net/bluetooth/hci_sock.h
 */
#define VENDOR_AF_BLUETOOTH 31
#define VENDOR_BTPROTO_HCI 1

/* struct sockaddr_hci { sa_family_t hci_family; u16 hci_dev; u16 hci_channel; } */
#define VENDOR_HCI_DEV_NONE 0xffff
#define VENDOR_HCI_CHANNEL_RAW 0
#define VENDOR_HCI_CHANNEL_USER 1
#define VENDOR_HCI_CHANNEL_MONITOR 2

/* SOL_HCI / HCI_FILTER */
#define VENDOR_SOL_HCI 0
#define VENDOR_HCI_FILTER 2

/* HCI packet types as used by the kernel (hci_skb_pkt_type) */
#define VENDOR_HCI_COMMAND_PKT 1
#define VENDOR_HCI_ACLDATA_PKT 2
#define VENDOR_HCI_SCODATA_PKT 3
#define VENDOR_HCI_EVENT_PKT 4
#define VENDOR_HCI_ISODATA_PKT 5

/* HCI packet types on the wire (H4) - identical numbering to the above. */
#define VENDOR_H4_TYPE_CMD 0x01
#define VENDOR_H4_TYPE_ACL 0x02
#define VENDOR_H4_TYPE_SCO 0x03
#define VENDOR_H4_TYPE_EVT 0x04
#define VENDOR_H4_TYPE_ISO 0x05

#ifdef __cplusplus
}
#endif

#endif /* PC_PTL_BT_VENDOR_LINUX_H */
