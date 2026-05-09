import Hummingbird
import LuminaVaultShared

typealias RegisterRequest = LuminaVaultShared.RegisterRequest
typealias LoginRequest = LuminaVaultShared.LoginRequest
typealias RefreshRequest = LuminaVaultShared.RefreshRequest
typealias AuthResponse = LuminaVaultShared.AuthResponse
typealias MFAVerifyRequest = LuminaVaultShared.MFAVerifyRequest
typealias MFAResendRequest = LuminaVaultShared.MFAResendRequest
typealias OAuthExchangeRequest = LuminaVaultShared.OAuthExchangeRequest
typealias ForgotPasswordRequest = LuminaVaultShared.ForgotPasswordRequest
typealias ResetPasswordRequest = LuminaVaultShared.ResetPasswordRequest
typealias MeResponse = LuminaVaultShared.MeResponse

extension AuthResponse: ResponseEncodable {}
extension MeResponse: ResponseEncodable {}
