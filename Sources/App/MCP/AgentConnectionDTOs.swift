import Hummingbird
import LuminaVaultShared

// The inbound-MCP wire types live in LuminaVaultShared (5.20.0). The server
// kept local copies until its Shared pin included them; only the response
// conformances remain here.
extension AgentConnectionDTO: @retroactive ResponseEncodable {}
extension AgentConnectionSetupDTO: @retroactive ResponseEncodable {}
extension AgentConnectionIssuedResponse: @retroactive ResponseEncodable {}
extension AgentConnectionsListResponse: @retroactive ResponseEncodable {}
