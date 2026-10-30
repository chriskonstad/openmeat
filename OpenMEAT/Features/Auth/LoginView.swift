import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenMEAT").font(.largeTitle.bold())
                        Text("Sign in with your ThermoWorks account to see your RFX probes.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(AccessibilityID.Login.email)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier(AccessibilityID.Login.password)
                }
                if let error = model.signInError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(AccessibilityID.Login.error)
                }
                Section {
                    Button {
                        Task { await model.signIn(email: email, password: password) }
                    } label: {
                        if model.phase == .signingIn {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || model.phase == .signingIn)
                    .accessibilityIdentifier(AccessibilityID.Login.signIn)
                }
                Section {
                    Button("Try demo mode (simulated probes)") { model.enterDemo() }
                        .accessibilityIdentifier(AccessibilityID.Login.demo)
                } footer: {
                    Text("OpenMEAT is an unofficial, open-source app and is not affiliated with ThermoWorks. Use the ThermoWorks app to pair and configure probes.")
                }
            }
        }
    }
}
