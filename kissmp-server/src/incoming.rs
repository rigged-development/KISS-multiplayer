use crate::*;

#[derive(Debug)]
pub enum IncomingEvent {
    ClientConnected(Connection),
    ConnectionLost,
    ClientCommand(shared::ClientCommand),
}

impl Server {
    pub fn decode_client_command_with_fallback(data: &[u8]) -> anyhow::Result<shared::ClientCommand> {
        if let Ok(command) = bincode::deserialize::<shared::ClientCommand>(data) {
            return Ok(command);
        }

        let legacy = bincode::deserialize::<shared::legacy::ClientCommand>(data)?;
        Ok(shared::legacy::client_command_from_legacy(legacy))
    }

    pub async fn handle_incoming_data(
        id: u32,
        data: Vec<u8>,
        client_events_tx: &mut mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        let client_command = Self::decode_client_command_with_fallback(&data)?;
        client_events_tx
            .send((id, IncomingEvent::ClientCommand(client_command)))
            .await?;
        Ok(())
    }
}
