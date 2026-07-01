import Foundation

func csrfToken(from cookies: [HTTPCookie]) -> String? {
    cookies.first(where: { $0.name == "csrftoken" })?.value
}
