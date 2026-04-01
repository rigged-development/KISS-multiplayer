use crate::vehicle::*;
use crate::{ClientCommand as CurrentClientCommand, ServerCommand as CurrentServerCommand};
use crate::{ClientInfoPrivate, ClientInfoPublic, ServerInfo as CurrentServerInfo};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerInfo {
    pub name: String,
    pub player_count: u8,
    pub client_id: u32,
    pub map: String,
    pub tickrate: u8,
    pub max_vehicles_per_client: u8,
    pub mods: Vec<(String, u32)>,
    pub server_identifier: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ClientCommand {
    ClientInfo(ClientInfoPrivate),
    VehicleUpdate(VehicleUpdate),
    VehicleData(VehicleData),
    GearboxUpdate(Gearbox),
    RemoveVehicle(u32),
    ResetVehicle(VehicleReset),
    Chat(String),
    RequestMods(Vec<String>),
    VehicleMetaUpdate(VehicleMeta),
    VehicleChanged(u32),
    CouplerAttached(CouplerAttached),
    CouplerDetached(CouplerDetached),
    ElectricsUndefinedUpdate(u32, ElectricsUndefined),
    VoiceChatPacket(Vec<u8>),
    SpatialUpdate([f32; 3], [f32; 3]),
    StartTalking,
    EndTalking,
    DataChunk {
        chunk_index: u32,
        total_chunks: u32,
        data: String,
    },
    Ping(u16),
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ServerCommand {
    VehicleUpdate(VehicleUpdate),
    VehicleSpawn(VehicleData),
    RemoveVehicle(u32),
    ResetVehicle(VehicleReset),
    Chat(String, Option<u32>),
    TransferFile(String),
    SendLua(String),
    PlayerInfoUpdate(ClientInfoPublic),
    VehicleMetaUpdate(VehicleMeta),
    PlayerDisconnected(u32),
    VehicleLuaCommand(u32, String),
    CouplerAttached(CouplerAttached),
    CouplerDetached(CouplerDetached),
    ElectricsUndefinedUpdate(u32, ElectricsUndefined),
    ServerInfo(ServerInfo),
    FilePart(String, Vec<u8>, u32, u32, u32),
    VoiceChatPacket(u32, [f32; 3], Vec<u8>),
    Pong(f64),
    VehicleSetPosition(u32, [f32; 3]),
    VehicleSetPositionRotation(u32, [f32; 3], [f32; 4]),
    VehicleResetInPlace(u32),
}

pub fn server_info_from_legacy(info: ServerInfo) -> CurrentServerInfo {
    CurrentServerInfo {
        name: info.name,
        player_count: info.player_count,
        client_id: info.client_id,
        map: info.map,
        tickrate: info.tickrate,
        max_vehicles_per_client: info.max_vehicles_per_client,
        mods: info
            .mods
            .into_iter()
            .map(|(name, size)| (name, size, String::new()))
            .collect(),
        server_identifier: info.server_identifier,
    }
}

pub fn server_info_to_legacy(info: CurrentServerInfo) -> ServerInfo {
    ServerInfo {
        name: info.name,
        player_count: info.player_count,
        client_id: info.client_id,
        map: info.map,
        tickrate: info.tickrate,
        max_vehicles_per_client: info.max_vehicles_per_client,
        mods: info
            .mods
            .into_iter()
            .map(|(name, size, _hash)| (name, size))
            .collect(),
        server_identifier: info.server_identifier,
    }
}

pub fn client_command_from_legacy(command: ClientCommand) -> CurrentClientCommand {
    match command {
        ClientCommand::ClientInfo(info) => CurrentClientCommand::ClientInfo(info),
        ClientCommand::VehicleUpdate(v) => CurrentClientCommand::VehicleUpdate(v),
        ClientCommand::VehicleData(v) => CurrentClientCommand::VehicleData(v),
        ClientCommand::GearboxUpdate(g) => CurrentClientCommand::GearboxUpdate(g),
        ClientCommand::RemoveVehicle(id) => CurrentClientCommand::RemoveVehicle(id),
        ClientCommand::ResetVehicle(v) => CurrentClientCommand::ResetVehicle(v),
        ClientCommand::Chat(msg) => CurrentClientCommand::Chat(msg),
        ClientCommand::RequestMods(mods) => CurrentClientCommand::RequestMods(mods),
        ClientCommand::VehicleMetaUpdate(meta) => CurrentClientCommand::VehicleMetaUpdate(meta),
        ClientCommand::VehicleChanged(id) => CurrentClientCommand::VehicleChanged(id),
        ClientCommand::CouplerAttached(data) => CurrentClientCommand::CouplerAttached(data),
        ClientCommand::CouplerDetached(data) => CurrentClientCommand::CouplerDetached(data),
        ClientCommand::ElectricsUndefinedUpdate(id, data) => {
            CurrentClientCommand::ElectricsUndefinedUpdate(id, data)
        }
        ClientCommand::VoiceChatPacket(data) => CurrentClientCommand::VoiceChatPacket(data),
        ClientCommand::SpatialUpdate(left, right) => CurrentClientCommand::SpatialUpdate(left, right),
        ClientCommand::StartTalking => CurrentClientCommand::StartTalking,
        ClientCommand::EndTalking => CurrentClientCommand::EndTalking,
        ClientCommand::DataChunk {
            chunk_index,
            total_chunks,
            data,
        } => CurrentClientCommand::DataChunk {
            chunk_index,
            total_chunks,
            data,
        },
        ClientCommand::Ping(v) => CurrentClientCommand::Ping(v),
    }
}

pub fn client_command_to_legacy(command: CurrentClientCommand) -> Option<ClientCommand> {
    match command {
        CurrentClientCommand::ClientInfo(info) => Some(ClientCommand::ClientInfo(info)),
        CurrentClientCommand::VehicleUpdate(v) => Some(ClientCommand::VehicleUpdate(v)),
        CurrentClientCommand::VehicleData(v) => Some(ClientCommand::VehicleData(v)),
        CurrentClientCommand::GearboxUpdate(g) => Some(ClientCommand::GearboxUpdate(g)),
        CurrentClientCommand::RemoveVehicle(id) => Some(ClientCommand::RemoveVehicle(id)),
        CurrentClientCommand::ResetVehicle(v) => Some(ClientCommand::ResetVehicle(v)),
        CurrentClientCommand::Chat(msg) => Some(ClientCommand::Chat(msg)),
        CurrentClientCommand::RequestMods(mods) => Some(ClientCommand::RequestMods(mods)),
        CurrentClientCommand::VehicleMetaUpdate(meta) => Some(ClientCommand::VehicleMetaUpdate(meta)),
        CurrentClientCommand::VehicleChanged(id) => Some(ClientCommand::VehicleChanged(id)),
        CurrentClientCommand::CouplerAttached(data) => Some(ClientCommand::CouplerAttached(data)),
        CurrentClientCommand::CouplerDetached(data) => Some(ClientCommand::CouplerDetached(data)),
        CurrentClientCommand::ElectricsUndefinedUpdate(id, data) => {
            Some(ClientCommand::ElectricsUndefinedUpdate(id, data))
        }
        CurrentClientCommand::VoiceChatPacket(data) => Some(ClientCommand::VoiceChatPacket(data)),
        CurrentClientCommand::SpatialUpdate(left, right) => Some(ClientCommand::SpatialUpdate(left, right)),
        CurrentClientCommand::StartTalking => Some(ClientCommand::StartTalking),
        CurrentClientCommand::EndTalking => Some(ClientCommand::EndTalking),
        CurrentClientCommand::DataChunk {
            chunk_index,
            total_chunks,
            data,
        } => Some(ClientCommand::DataChunk {
            chunk_index,
            total_chunks,
            data,
        }),
        CurrentClientCommand::Ping(v) => Some(ClientCommand::Ping(v)),
        CurrentClientCommand::SetVoiceChatDistance(_)
        | CurrentClientCommand::SetVoiceChatPlayerVolume(_, _)
        | CurrentClientCommand::SetVoiceChatInputVolume(_)
        | CurrentClientCommand::SetVoiceChatInputDevice(_)
        | CurrentClientCommand::SetVoiceChatNoiseSuppression(_)
        | CurrentClientCommand::SetVoiceChatEchoSuppression(_)
        | CurrentClientCommand::SetVoiceChatNoiseSuppressionLevel(_)
        | CurrentClientCommand::SetVoiceChatEchoSuppressionLevel(_)
        | CurrentClientCommand::SetVoiceChatCurveProfile(_)
        | CurrentClientCommand::SetVoiceChatFrequency(_)
        | CurrentClientCommand::RequestVoiceChatInputDevices => None,
    }
}

pub fn server_command_from_legacy(command: ServerCommand) -> CurrentServerCommand {
    match command {
        ServerCommand::VehicleUpdate(v) => CurrentServerCommand::VehicleUpdate(v),
        ServerCommand::VehicleSpawn(v) => CurrentServerCommand::VehicleSpawn(v),
        ServerCommand::RemoveVehicle(id) => CurrentServerCommand::RemoveVehicle(id),
        ServerCommand::ResetVehicle(v) => CurrentServerCommand::ResetVehicle(v),
        ServerCommand::Chat(msg, source) => CurrentServerCommand::Chat(msg, source),
        ServerCommand::TransferFile(path) => CurrentServerCommand::TransferFile(path),
        ServerCommand::SendLua(code) => CurrentServerCommand::SendLua(code),
        ServerCommand::PlayerInfoUpdate(info) => CurrentServerCommand::PlayerInfoUpdate(info),
        ServerCommand::VehicleMetaUpdate(meta) => CurrentServerCommand::VehicleMetaUpdate(meta),
        ServerCommand::PlayerDisconnected(id) => CurrentServerCommand::PlayerDisconnected(id),
        ServerCommand::VehicleLuaCommand(id, code) => CurrentServerCommand::VehicleLuaCommand(id, code),
        ServerCommand::CouplerAttached(data) => CurrentServerCommand::CouplerAttached(data),
        ServerCommand::CouplerDetached(data) => CurrentServerCommand::CouplerDetached(data),
        ServerCommand::ElectricsUndefinedUpdate(id, data) => {
            CurrentServerCommand::ElectricsUndefinedUpdate(id, data)
        }
        ServerCommand::ServerInfo(info) => CurrentServerCommand::ServerInfo(server_info_from_legacy(info)),
        ServerCommand::FilePart(name, data, chunk_n, file_size, data_left) => {
            CurrentServerCommand::FilePart(name, data, chunk_n, file_size, data_left)
        }
        ServerCommand::VoiceChatPacket(client_id, pos, data) => {
            CurrentServerCommand::VoiceChatPacket(client_id, pos, data)
        }
        ServerCommand::Pong(v) => CurrentServerCommand::Pong(v),
        ServerCommand::VehicleSetPosition(id, pos) => CurrentServerCommand::VehicleSetPosition(id, pos),
        ServerCommand::VehicleSetPositionRotation(id, pos, rot) => {
            CurrentServerCommand::VehicleSetPositionRotation(id, pos, rot)
        }
        ServerCommand::VehicleResetInPlace(id) => CurrentServerCommand::VehicleResetInPlace(id),
    }
}

pub fn server_command_to_legacy(command: CurrentServerCommand) -> Option<ServerCommand> {
    match command {
        CurrentServerCommand::VehicleUpdate(v) => Some(ServerCommand::VehicleUpdate(v)),
        CurrentServerCommand::VehicleSpawn(v) => Some(ServerCommand::VehicleSpawn(v)),
        CurrentServerCommand::RemoveVehicle(id) => Some(ServerCommand::RemoveVehicle(id)),
        CurrentServerCommand::ResetVehicle(v) => Some(ServerCommand::ResetVehicle(v)),
        CurrentServerCommand::Chat(msg, source) => Some(ServerCommand::Chat(msg, source)),
        CurrentServerCommand::TransferFile(path) => Some(ServerCommand::TransferFile(path)),
        CurrentServerCommand::SendLua(code) => Some(ServerCommand::SendLua(code)),
        CurrentServerCommand::PlayerInfoUpdate(info) => Some(ServerCommand::PlayerInfoUpdate(info)),
        CurrentServerCommand::VehicleMetaUpdate(meta) => Some(ServerCommand::VehicleMetaUpdate(meta)),
        CurrentServerCommand::PlayerDisconnected(id) => Some(ServerCommand::PlayerDisconnected(id)),
        CurrentServerCommand::VehicleLuaCommand(id, code) => Some(ServerCommand::VehicleLuaCommand(id, code)),
        CurrentServerCommand::CouplerAttached(data) => Some(ServerCommand::CouplerAttached(data)),
        CurrentServerCommand::CouplerDetached(data) => Some(ServerCommand::CouplerDetached(data)),
        CurrentServerCommand::ElectricsUndefinedUpdate(id, data) => {
            Some(ServerCommand::ElectricsUndefinedUpdate(id, data))
        }
        CurrentServerCommand::ServerInfo(info) => {
            Some(ServerCommand::ServerInfo(server_info_to_legacy(info)))
        }
        CurrentServerCommand::FilePart(name, data, chunk_n, file_size, data_left) => {
            Some(ServerCommand::FilePart(name, data, chunk_n, file_size, data_left))
        }
        CurrentServerCommand::VoiceChatPacket(client_id, pos, data) => {
            Some(ServerCommand::VoiceChatPacket(client_id, pos, data))
        }
        CurrentServerCommand::Pong(v) => Some(ServerCommand::Pong(v)),
        CurrentServerCommand::VehicleSetPosition(id, pos) => {
            Some(ServerCommand::VehicleSetPosition(id, pos))
        }
        CurrentServerCommand::VehicleSetPositionRotation(id, pos, rot) => {
            Some(ServerCommand::VehicleSetPositionRotation(id, pos, rot))
        }
        CurrentServerCommand::VehicleResetInPlace(id) => Some(ServerCommand::VehicleResetInPlace(id)),
        CurrentServerCommand::VoiceChatFrequencyUpdate(_, _) => None,
    }
}

