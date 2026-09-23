import Hummingbird
import LuminaVaultShared

// The Agents-page wire types live in LuminaVaultShared (5.20.0). The server
// kept local copies until its Shared pin included them; only the response
// conformances remain here.
extension AgentInstancesResponse: @retroactive ResponseEncodable {}
extension AgentSessionsResponse: @retroactive ResponseEncodable {}
extension AgentSessionMessagesResponse: @retroactive ResponseEncodable {}
