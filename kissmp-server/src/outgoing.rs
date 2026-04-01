use crate::*;

impl Server {
    pub fn handle_outgoing_data(command: shared::ServerCommand) -> Option<Vec<u8>> {
        let legacy_command = shared::legacy::server_command_to_legacy(command)?;
        bincode::serialize(&legacy_command).ok()
    }
}
