#!/usr/bin/env python3
"""Capture real RNode KISS frames over USB serial for the Swift RNode tests.

Read-only: only query commands are sent (frequency/bandwidth 0 = ask, TX power / SF / CR /
radio state 0xFF = ask), plus detect, firmware version, platform, MCU, board, EEPROM dump,
stat counters and CMD_READY, then CMD_LEAVE. Nothing is written to EEPROM and no radio
parameter is changed. Run with the Reticulum venv's python (it has pyserial), with rnsd
stopped and no app connected over Bluetooth:

    /Volumes/Code-Docker/reticulum/venv/bin/python capture_rnode.py /dev/cu.usbmodem113101 rnode-wisblock.json
"""
import json, sys, time, datetime
import serial

FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD

def frame(cmd, *payload):
    return bytes([FEND, cmd, *payload, FEND])

EXCHANGES = [
    # rnodeconf's detect bundle: detect, fw version, platform, mcu, board, device hash, fw hash target, fw hash
    ("detect", frame(0x08, 0x73) + frame(0x50, 0x00) + frame(0x48, 0x00) + frame(0x49, 0x00) + frame(0x47, 0x00)
               + frame(0x56, 0x01) + frame(0x60, 0x01) + frame(0x60, 0x02), 1.0),
    ("rom_read", frame(0x51, 0x00), 1.5),
    ("frequency", frame(0x01, 0, 0, 0, 0), 0.6),
    ("bandwidth", frame(0x02, 0, 0, 0, 0), 0.6),
    ("txpower", frame(0x03, 0xFF), 0.6),
    ("spreading_factor", frame(0x04, 0xFF), 0.6),
    ("coding_rate", frame(0x05, 0xFF), 0.6),
    ("radio_state", frame(0x06, 0xFF), 0.6),
    ("stat_rx", frame(0x21, 0x00), 0.6),
    ("stat_tx", frame(0x22, 0x00), 0.6),
    ("stat_rssi", frame(0x23, 0x00), 0.6),
    ("ready", frame(0x0F, 0x00), 0.6),
    ("random", frame(0x40, 0x00), 0.6),
    ("idle", b"", 11.0),   # unsolicited frames (battery every ~5 s)
    ("leave", frame(0x0A, 0xFF), 0.6),
]

def hexs(b):
    return " ".join(f"{x:02x}" for x in b)

def main():
    port, out = sys.argv[1], sys.argv[2]
    s = serial.Serial(port=port, baudrate=115200, timeout=0)
    time.sleep(2.5)
    s.read(65536)  # drop anything buffered (boot/reset frames)
    results = []
    for name, tx, wait in EXCHANGES:
        if tx:
            s.write(tx)
        deadline = time.time() + wait
        rx = b""
        while time.time() < deadline:
            chunk = s.read(65536)
            if chunk:
                rx += chunk
            else:
                time.sleep(0.02)
        results.append({"name": name, "sent": hexs(tx), "received": hexs(rx)})
        print(f"{name:17s} sent {len(tx):3d}  got {len(rx):4d} bytes: {hexs(rx[:48])}{' …' if len(rx) > 48 else ''}")
    s.close()
    doc = {
        "device": "RAK WisBlock RAK4631 (nRF52840 + SX1262), RNode firmware 1.86, product 10:12:51, serial 00:00:00:03",
        "captured": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "transport": "USB serial 115200 (the same KISS frames travel over Bluetooth LE, Nordic UART service)",
        "rnodeconf_info": {
            "product": "RAK4631 779 - 928 MHz (10:12:51)",
            "device_signature": "Validated - Local signature",
            "firmware_version": "1.86",
            "hardware_revision": "1",
            "serial_number": "00:00:00:03",
            "modem_chip": "SX1262",
            "frequency_range": "779.0 MHz - 928.0 MHz",
            "max_tx_power": "22 dBm",
            "manufactured_local": "2026-10-07 20:29:45",
            "device_mode": "Normal (host-controlled)",
        },
        "exchanges": results,
    }
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print("wrote", out)

if __name__ == "__main__":
    main()
