"""Regenerates meshtastic-vectors.json: protobuf bytes built with the official
Meshtastic Python package (run with the Den's venv). Only the resulting bytes
are used by the Swift tests; no Meshtastic code is linked into the app."""
import json, pathlib
from meshtastic.protobuf import module_config_pb2
from meshtastic.protobuf import mesh_pb2, channel_pb2, portnums_pb2, admin_pb2, config_pb2, apponly_pb2, telemetry_pb2
import base64

def hx(msg): return msg.SerializeToString().hex()
V = {}

p = mesh_pb2.MeshPacket(); p.to = 0xFFFFFFFF; p.channel = 1; p.id = 12345; p.rx_time = 1790000000
setattr(p, 'from', 0x9E766B18)
p.rx_snr = 6.5; p.hop_limit = 3; p.hop_start = 3; p.rx_rssi = -88; p.relay_node = 0x18
p.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; p.decoded.payload = "WG W FOX7 WARMER -94>-88 BEST -85 BRG 045".encode()
V["fromradio_text"] = hx(mesh_pb2.FromRadio(id=7, packet=p))

q = mesh_pb2.MeshPacket(); setattr(q, 'from', 0x0A1B2C3D); q.to = 0x9E766B18; q.id = 99; q.hop_start = 3; q.hop_limit = 1; q.via_mqtt = True; q.rx_snr = -3.25; q.rx_rssi = -112
pos = mesh_pb2.Position(latitude_i=384_123_456, longitude_i=-852_345_678)
q.decoded.portnum = portnums_pb2.POSITION_APP; q.decoded.payload = pos.SerializeToString()
V["fromradio_position"] = hx(mesh_pb2.FromRadio(packet=q))

e = mesh_pb2.MeshPacket(); setattr(e, 'from', 0x11223344); e.to = 0xFFFFFFFF; e.id = 5; e.encrypted = b"\x01\x02\x03"
V["fromradio_encrypted"] = hx(mesh_pb2.FromRadio(packet=e))

V["fromradio_myinfo"] = hx(mesh_pb2.FromRadio(my_info=mesh_pb2.MyNodeInfo(my_node_num=0xDEADBEEF)))
ni = mesh_pb2.NodeInfo(num=0x9E766B18, snr=7.75); ni.user.id = "!9e766b18"; ni.user.long_name = "Wildcat Den"; ni.user.short_name = "DEN"
V["fromradio_nodeinfo"] = hx(mesh_pb2.FromRadio(node_info=ni))
ch = channel_pb2.Channel(index=1, role=channel_pb2.Channel.SECONDARY); ch.settings.name = "WGHUNT"
V["fromradio_channel"] = hx(mesh_pb2.FromRadio(channel=ch))
V["fromradio_config_complete"] = hx(mesh_pb2.FromRadio(config_complete_id=424242))

t = mesh_pb2.MeshPacket(); t.to = 0xFFFFFFFF; t.channel = 1; t.id = 777
t.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; t.decoded.payload = "WG SIG FOX7 -88 6.5".encode()
V["toradio_text_broadcast"] = hx(mesh_pb2.ToRadio(packet=t))
d = mesh_pb2.MeshPacket(); d.to = 0x9E766B18; d.id = 778; d.want_ack = True
d.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; d.decoded.payload = "WG PING ab12".encode()
V["toradio_text_dm"] = hx(mesh_pb2.ToRadio(packet=d))
V["toradio_want_config"] = hx(mesh_pb2.ToRadio(want_config_id=123456789))
V["toradio_heartbeat"] = hx(mesh_pb2.ToRadio(heartbeat=mesh_pb2.Heartbeat()))

b = mesh_pb2.MeshPacket(); b.to = 0xFFFFFFFF; b.channel = 1; b.id = 779
b.decoded.portnum = portnums_pb2.POSITION_APP; b.decoded.payload = mesh_pb2.Position(time=1790000000).SerializeToString()
V["toradio_position_beacon"] = hx(mesh_pb2.ToRadio(packet=b))
f = mesh_pb2.MeshPacket(); f.to = 0xFFFFFFFF; f.id = 780
f.decoded.portnum = portnums_pb2.POSITION_APP
f.decoded.payload = mesh_pb2.Position(latitude_i=391031000, longitude_i=-845120000, altitude=256, time=1790000000).SerializeToString()
V["toradio_position_full"] = hx(mesh_pb2.ToRadio(packet=f))

tr = mesh_pb2.MeshPacket(); tr.to = 0x9E766B18; tr.id = 781; tr.channel = 1
tr.decoded.portnum = portnums_pb2.TRACEROUTE_APP; tr.decoded.payload = mesh_pb2.RouteDiscovery().SerializeToString(); tr.decoded.want_response = True
V["toradio_traceroute"] = hx(mesh_pb2.ToRadio(packet=tr))

# Messaging: acks, naks, replies and reactions.
ack = mesh_pb2.MeshPacket(); setattr(ack, 'from', 0x9E766B18); ack.to = 0xDEADBEEF; ack.id = 900; ack.channel = 0
ack.decoded.portnum = portnums_pb2.ROUTING_APP; ack.decoded.request_id = 777
ack.decoded.payload = mesh_pb2.Routing(error_reason=mesh_pb2.Routing.NONE).SerializeToString()
V["fromradio_ack"] = hx(mesh_pb2.FromRadio(packet=ack))
nak = mesh_pb2.MeshPacket(); setattr(nak, 'from', 0xDEADBEEF); nak.to = 0xDEADBEEF; nak.id = 901
nak.decoded.portnum = portnums_pb2.ROUTING_APP; nak.decoded.request_id = 778
nak.decoded.payload = mesh_pb2.Routing(error_reason=mesh_pb2.Routing.MAX_RETRANSMIT).SerializeToString()
V["fromradio_nak"] = hx(mesh_pb2.FromRadio(packet=nak))
rp = mesh_pb2.MeshPacket(); setattr(rp, 'from', 0x9E766B18); rp.to = 0xFFFFFFFF; rp.id = 902; rp.channel = 1
rp.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; rp.decoded.payload = "on my way".encode(); rp.decoded.reply_id = 777
V["fromradio_reply"] = hx(mesh_pb2.FromRadio(packet=rp))
re = mesh_pb2.MeshPacket(); setattr(re, 'from', 0x9E766B18); re.to = 0xFFFFFFFF; re.id = 903
re.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; re.decoded.payload = "👍".encode(); re.decoded.reply_id = 777; re.decoded.emoji = 1
V["fromradio_reaction"] = hx(mesh_pb2.FromRadio(packet=re))
tb = mesh_pb2.MeshPacket(); tb.to = 0xFFFFFFFF; tb.channel = 1; tb.id = 904; tb.want_ack = True
tb.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; tb.decoded.payload = "hello mesh".encode()
V["toradio_text_broadcast_ack"] = hx(mesh_pb2.ToRadio(packet=tb))
tr2 = mesh_pb2.MeshPacket(); tr2.to = 0x9E766B18; tr2.id = 905; tr2.want_ack = True
tr2.decoded.portnum = portnums_pb2.TEXT_MESSAGE_APP; tr2.decoded.payload = "❤️".encode(); tr2.decoded.reply_id = 902; tr2.decoded.emoji = 1
V["toradio_reaction_dm"] = hx(mesh_pb2.ToRadio(packet=tr2))

# ---- Admin / config ----
ME = 0xDEADBEEF
def admin_packet(adm, pid, want_response=False):
    p = mesh_pb2.MeshPacket(); p.to = ME; p.id = pid
    p.decoded.portnum = portnums_pb2.ADMIN_APP; p.decoded.payload = adm.SerializeToString()
    if want_response: p.decoded.want_response = True
    return mesh_pb2.ToRadio(packet=p)
V["admin_get_owner"] = hx(admin_packet(admin_pb2.AdminMessage(get_owner_request=True), 1000, True))
PK = bytes(range(1, 9))
V["admin_begin"] = hx(admin_packet(admin_pb2.AdminMessage(begin_edit_settings=True, session_passkey=PK), 1001))
V["admin_commit"] = hx(admin_packet(admin_pb2.AdminMessage(commit_edit_settings=True, session_passkey=PK), 1002))
V["admin_reboot"] = hx(admin_packet(admin_pb2.AdminMessage(reboot_seconds=5, session_passkey=PK), 1003))
u = mesh_pb2.User(id="!deadbeef", long_name="Seth Walker", short_name="SW", hw_model=mesh_pb2.HardwareModel.Value("HELTEC_V3"), public_key=bytes(32))
V["user_raw"] = u.SerializeToString().hex()
u2 = mesh_pb2.User(); u2.CopyFrom(u); u2.long_name = "Wildcat Scout"; u2.short_name = "WCS"
V["admin_set_owner"] = hx(admin_packet(admin_pb2.AdminMessage(set_owner=u2, session_passkey=PK), 1004))
lora = config_pb2.Config.LoRaConfig(use_preset=True, modem_preset=config_pb2.Config.LoRaConfig.LONG_FAST, region=config_pb2.Config.LoRaConfig.UNSET,
        hop_limit=3, tx_enabled=True, tx_power=0, sx126x_rx_boosted_gain=True, ignore_incoming=[0x1234], config_ok_to_mqtt=True)
V["lora_raw"] = lora.SerializeToString().hex()
V["fromradio_config_lora"] = hx(mesh_pb2.FromRadio(config=config_pb2.Config(lora=lora)))
lora2 = config_pb2.Config.LoRaConfig(); lora2.CopyFrom(lora); lora2.region = config_pb2.Config.LoRaConfig.US; lora2.hop_limit = 4
V["lora_patched_raw"] = lora2.SerializeToString().hex()
V["admin_set_lora"] = hx(admin_packet(admin_pb2.AdminMessage(set_config=config_pb2.Config(lora=lora2), session_passkey=PK), 1005))
dev = config_pb2.Config.DeviceConfig(role=config_pb2.Config.DeviceConfig.CLIENT, node_info_broadcast_secs=10800)
V["fromradio_config_device"] = hx(mesh_pb2.FromRadio(config=config_pb2.Config(device=dev)))
pos = config_pb2.Config.PositionConfig(position_broadcast_secs=900, position_broadcast_smart_enabled=True, gps_mode=config_pb2.Config.PositionConfig.ENABLED)
V["fromradio_config_position"] = hx(mesh_pb2.FromRadio(config=config_pb2.Config(position=pos)))
md = mesh_pb2.DeviceMetadata(firmware_version="2.7.11.ee68575", device_state_version=24, hasBluetooth=True, hw_model=mesh_pb2.HardwareModel.Value("HELTEC_V3"))
V["fromradio_metadata"] = hx(mesh_pb2.FromRadio(metadata=md))
resp = mesh_pb2.MeshPacket(); setattr(resp, 'from', ME); resp.to = ME; resp.id = 1100
resp.decoded.portnum = portnums_pb2.ADMIN_APP; resp.decoded.request_id = 1000
resp.decoded.payload = admin_pb2.AdminMessage(get_owner_response=u, session_passkey=PK).SerializeToString()
V["fromradio_admin_owner_response"] = hx(mesh_pb2.FromRadio(packet=resp))
cs = channel_pb2.ChannelSettings(psk=bytes([1]), name="", module_settings=channel_pb2.ModuleSettings(position_precision=13))
hunt = channel_pb2.ChannelSettings(psk=bytes(range(32)), name="WGHUNT", uplink_enabled=False)
ch = channel_pb2.Channel(index=1, settings=hunt, role=channel_pb2.Channel.SECONDARY)
V["fromradio_channel_full"] = hx(mesh_pb2.FromRadio(channel=ch))
V["admin_set_channel"] = hx(admin_packet(admin_pb2.AdminMessage(set_channel=ch, session_passkey=PK), 1006))
V["admin_remove_channel"] = hx(admin_packet(admin_pb2.AdminMessage(set_channel=channel_pb2.Channel(index=2, role=channel_pb2.Channel.DISABLED), session_passkey=PK), 1007))
cset = apponly_pb2.ChannelSet(settings=[cs, hunt], lora_config=config_pb2.Config.LoRaConfig(use_preset=True, region=config_pb2.Config.LoRaConfig.US, hop_limit=3, tx_enabled=True))
V["channelset_url"] = "https://meshtastic.org/e/#" + base64.urlsafe_b64encode(cset.SerializeToString()).decode().replace("=", "")
V["channelset_hunt_only_add_url"] = "https://meshtastic.org/e/?add=true#" + base64.urlsafe_b64encode(apponly_pb2.ChannelSet(settings=[hunt]).SerializeToString()).decode().replace("=", "")

# ---- Nodes: full NodeInfo, telemetry, traceroute, favourites ----
nif = mesh_pb2.NodeInfo(num=0x716C668C, snr=6.25, last_heard=1790000000, hops_away=2, via_mqtt=True, is_favorite=True)
nif.user.id = "!716c668c"; nif.user.long_name = "Wildcat Go 668c"; nif.user.short_name = "GO"
nif.user.hw_model = mesh_pb2.HardwareModel.Value("RAK4631"); nif.user.role = config_pb2.Config.DeviceConfig.ROUTER
nif.position.latitude_i = 391031000; nif.position.longitude_i = -845120000; nif.position.altitude = 250; nif.position.time = 1789990000
nif.device_metrics.battery_level = 87; nif.device_metrics.voltage = 4.05; nif.device_metrics.channel_utilization = 12.5
nif.device_metrics.air_util_tx = 1.25; nif.device_metrics.uptime_seconds = 86400
V["fromradio_nodeinfo_full"] = hx(mesh_pb2.FromRadio(node_info=nif))
tp = mesh_pb2.MeshPacket(); setattr(tp, 'from', 0x716C668C); tp.to = 0xFFFFFFFF; tp.id = 1200; tp.hop_start = 3; tp.hop_limit = 3; tp.rx_snr = 5.5; tp.rx_rssi = -95
tp.decoded.portnum = portnums_pb2.TELEMETRY_APP
tp.decoded.payload = telemetry_pb2.Telemetry(time=1790000100, device_metrics=telemetry_pb2.DeviceMetrics(battery_level=101, voltage=5.1, channel_utilization=3.5, air_util_tx=0.5, uptime_seconds=3600)).SerializeToString()
V["fromradio_telemetry"] = hx(mesh_pb2.FromRadio(packet=tp))
ni = mesh_pb2.MeshPacket(); setattr(ni, 'from', 0x0BADF00D); ni.to = 0xFFFFFFFF; ni.id = 1201
ni.decoded.portnum = portnums_pb2.NODEINFO_APP
ni.decoded.payload = mesh_pb2.User(id="!0badf00d", long_name="New Hiker", short_name="HIKE", hw_model=mesh_pb2.HardwareModel.Value("T_ECHO")).SerializeToString()
V["fromradio_nodeinfo_packet"] = hx(mesh_pb2.FromRadio(packet=ni))
rt = mesh_pb2.MeshPacket(); setattr(rt, 'from', 0x716C668C); rt.to = 0xDEADBEEF; rt.id = 1202
rt.decoded.portnum = portnums_pb2.TRACEROUTE_APP; rt.decoded.request_id = 781
rt.decoded.payload = mesh_pb2.RouteDiscovery(route=[0x11111111, 0x22222222], snr_towards=[24, -8, 10], route_back=[0x22222222], snr_back=[12, 4]).SerializeToString()
V["fromradio_traceroute"] = hx(mesh_pb2.FromRadio(packet=rt))
V["admin_set_favorite"] = hx(admin_packet(admin_pb2.AdminMessage(set_favorite_node=0x716C668C, session_passkey=PK), 1008))
V["admin_remove_favorite"] = hx(admin_packet(admin_pb2.AdminMessage(remove_favorite_node=0x716C668C, session_passkey=PK), 1009))
V["admin_set_ignored"] = hx(admin_packet(admin_pb2.AdminMessage(set_ignored_node=0x716C668C, session_passkey=PK), 1010))
V["admin_remove_ignored"] = hx(admin_packet(admin_pb2.AdminMessage(remove_ignored_node=0x716C668C, session_passkey=PK), 1011))
V["admin_remove_node"] = hx(admin_packet(admin_pb2.AdminMessage(remove_by_nodenum=0x716C668C, session_passkey=PK), 1012))

fp = mesh_pb2.Position(latitude_i=391031000, longitude_i=-845120000, altitude=250, time=1790000000)
V["admin_set_fixed_position"] = hx(admin_packet(admin_pb2.AdminMessage(set_fixed_position=fp, session_passkey=PK), 1013))
V["admin_remove_fixed_position"] = hx(admin_packet(admin_pb2.AdminMessage(remove_fixed_position=True, session_passkey=PK), 1014))
nch = mesh_pb2.NodeInfo(num=0x53FD8B02, channel=4); nch.user.id = "!53fd8b02"; nch.user.short_name = "BAG"
V["fromradio_nodeinfo_channel"] = hx(mesh_pb2.FromRadio(node_info=nch))

pa = mesh_pb2.MeshPacket(); pa.to = 0xFFFFFFFF; pa.id = 1300; pa.channel = 1; pa.want_ack = True
pa.decoded.portnum = portnums_pb2.PRIVATE_APP; pa.decoded.payload = bytes([0x57,0x47,0x47,1,9,9,9,9])
V["toradio_private_app"] = hx(mesh_pb2.ToRadio(packet=pa))
V["fromradio_private_app"] = hx(mesh_pb2.FromRadio(packet=mesh_pb2.MeshPacket(**{'from':0x716C668C}, to=0xFFFFFFFF, id=1301, channel=1, decoded=mesh_pb2.Data(portnum=portnums_pb2.PRIVATE_APP, payload=bytes([0x57,0x47,0x47,1,7])))))
print("PRIVATE_APP", portnums_pb2.PRIVATE_APP)

# Module config: telemetry as the node reports it, then patched for a fox heartbeat.
tel = module_config_pb2.ModuleConfig.TelemetryConfig(device_update_interval=1800, environment_update_interval=900, environment_screen_enabled=True)
V["fromradio_module_telemetry"] = hx(mesh_pb2.FromRadio(moduleConfig=module_config_pb2.ModuleConfig(telemetry=tel)))
tel2 = module_config_pb2.ModuleConfig.TelemetryConfig(device_update_interval=60, environment_update_interval=900, environment_screen_enabled=True, device_telemetry_enabled=True)
V["admin_set_module_telemetry"] = hx(admin_packet(admin_pb2.AdminMessage(set_module_config=module_config_pb2.ModuleConfig(telemetry=tel2), session_passkey=PK), 1015))
ext = module_config_pb2.ModuleConfig.ExternalNotificationConfig(enabled=True, output_ms=1000, alert_message=True, alert_message_buzzer=True, use_pwm=True)
V["admin_set_module_extnotif"] = hx(admin_packet(admin_pb2.AdminMessage(set_module_config=module_config_pb2.ModuleConfig(external_notification=ext), session_passkey=PK), 1016))
sf = module_config_pb2.ModuleConfig.StoreForwardConfig(enabled=True, is_server=True)
V["admin_set_module_storeforward"] = hx(admin_packet(admin_pb2.AdminMessage(set_module_config=module_config_pb2.ModuleConfig(store_forward=sf), session_passkey=PK), 1017))
posc = config_pb2.Config.PositionConfig(position_broadcast_secs=900, position_broadcast_smart_enabled=True, gps_update_interval=120, gps_mode=config_pb2.Config.PositionConfig.ENABLED)
V["fromradio_config_position_gps"] = hx(mesh_pb2.FromRadio(config=config_pb2.Config(position=posc)))
posf = config_pb2.Config.PositionConfig(position_broadcast_secs=43200, gps_update_interval=120, gps_mode=config_pb2.Config.PositionConfig.DISABLED)
V["admin_set_position_hidden"] = hx(admin_packet(admin_pb2.AdminMessage(set_config=config_pb2.Config(position=posf), session_passkey=PK), 1018))

out = pathlib.Path(__file__).with_name("meshtastic-vectors.json")
out.write_text(json.dumps(V, indent=2) + "\n")
print(out, len(V))
