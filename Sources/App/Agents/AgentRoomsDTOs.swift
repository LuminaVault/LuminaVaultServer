import Hummingbird
import LuminaVaultShared

// The agent-room wire types live in LuminaVaultShared (5.20.0). The server
// kept local copies until its Shared pin included them; only the response
// conformances remain here.
extension AgentRoomDTO: @retroactive ResponseEncodable {}
extension AgentRoomsResponse: @retroactive ResponseEncodable {}
extension AgentRoomDetailResponse: @retroactive ResponseEncodable {}
extension AgentRoomCandidatesResponse: @retroactive ResponseEncodable {}
