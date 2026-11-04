import CoreImage.CIFilterBuiltins
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPortal = false
    @State private var portalToShow = PortalDetector.probeURL
    @State private var deviceMAC = ""
    @State private var macMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                qrSection
                deviceSection
                proxySection
            }
            .navigationTitle("PuenteWiFi")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.appBecameActive() }
        }
        .sheet(isPresented: $showPortal) {
            PortalSheet(url: portalToShow) {
                Task { await model.checkConnectivity() }
            }
        }
    }

    // MARK: Step 1

    private var statusSection: some View {
        Section {
            statusRow
            Button {
                portalToShow = model.portalURL ?? PortalDetector.probeURL
                showPortal = true
            } label: {
                Label("Abrir portal y aceptar términos", systemImage: "safari")
            }
            Button {
                Task { await model.checkConnectivity() }
            } label: {
                Label("Volver a comprobar", systemImage: "arrow.clockwise")
            }
            .disabled(model.connectivity == .checking)
        } header: {
            Text("1. Conecta este iPhone")
        } footer: {
            Text("Si el portal no carga, desactiva los datos móviles mientras aceptas los términos: iOS puede enviar el tráfico por ahí cuando el Wi-Fi aún no tiene Internet.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.connectivity {
        case .unknown:
            Label("Sin comprobar", systemImage: "questionmark.circle")
        case .checking:
            HStack {
                ProgressView()
                Text("Comprobando el Wi-Fi…")
            }
        case .online:
            Label("Wi-Fi con acceso a Internet", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .portal(let url):
            VStack(alignment: .leading, spacing: 4) {
                Label("Portal detectado", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(url.host ?? url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("No se pudo comprobar por Wi-Fi", systemImage: "wifi.slash")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 2

    private var qrSection: some View {
        Section {
            VStack(spacing: 8) {
                QRCodeView(text: PortalDetector.universalTriggerURL.absoluteString)
                    .frame(width: 180, height: 180)
                Text(PortalDetector.universalTriggerURL.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } header: {
            Text("2. Abre el portal en otro dispositivo")
        } footer: {
            Text("Conecta el otro dispositivo al mismo Wi-Fi público y escanea el código o escribe la dirección en su navegador. Es la solución más fiable: el portal se abre con los datos de ese dispositivo y no depende del iPhone.")
        }
    }

    // MARK: Step 3

    private var deviceSection: some View {
        Section {
            TextField("MAC del dispositivo (AA:BB:CC:DD:EE:FF)", text: $deviceMAC)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button {
                openPortalForDevice()
            } label: {
                Label("Aceptar términos para ese dispositivo", systemImage: "tv")
            }
            .disabled(deviceMAC.isEmpty)
            if let macMessage {
                Label(macMessage, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("3. Roku, Switch u otro sin navegador")
        } footer: {
            Text("Conecta el dispositivo al Wi-Fi público y haz esto antes de aceptar en el iPhone. Solo funciona si el portal incluye la MAC en su enlace. Roku: Ajustes > Red > Acerca de. Switch: Configuración de la consola > Internet.")
        }
    }

    private func openPortalForDevice() {
        guard PortalMACRewriter.normalizedMAC(deviceMAC) != nil else {
            macMessage = "Esa MAC no es válida. Debe tener 12 caracteres hexadecimales."
            return
        }
        guard let portal = model.lastPortalURL else {
            macMessage = "No se ha detectado el portal. Pulsa «Volver a comprobar». Si este iPhone ya aceptó los términos, olvida la red y vuelve a unirte."
            return
        }
        guard let rewritten = PortalMACRewriter.rewrite(portalURL: portal, deviceMAC: deviceMAC) else {
            macMessage = "Este portal no incluye la MAC en su enlace, así que este método no sirve aquí."
            return
        }
        macMessage = "Portal abierto con la MAC indicada. Acepta los términos y comprueba la conexión en el dispositivo."
        portalToShow = rewritten
        showPortal = true
    }

    // MARK: Step 4

    private var proxySection: some View {
        Section {
            Toggle("Compartir Internet por proxy", isOn: $model.proxyWanted)

            if case .failed(let message) = model.proxyState {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            if let port = model.proxyPort {
                if model.addresses.isEmpty {
                    Text("Sin dirección de red. Conéctate al Wi-Fi.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.addresses) { address in
                    copyRow(address.label, value: "\(address.ip):\(port)")
                }
                copyRow("Usuario", value: model.credentials.username)
                copyRow("Contraseña", value: model.credentials.password)
                Button("Cambiar contraseña") { model.regeneratePassword() }
                LabeledContent("Conexiones activas", value: "\(model.stats.activeConnections)")
                LabeledContent(
                    "Datos transferidos",
                    value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.stats.bytesTransferred), countStyle: .file)
                )
            }
        } header: {
            Text("4. Proxy (Switch y otros compatibles)")
        } footer: {
            Text("En la Switch: Internet > tu red > Cambiar ajustes > Ajustes de proxy. Usa la dirección, el puerto, el usuario y la contraseña de arriba. Roku no admite proxy. Mantén esta app abierta y en pantalla: iOS la pausa en segundo plano. Solo pasa tráfico web, no juego en línea directo, y la red debe permitir que los dispositivos se vean entre sí.")
        }
    }

    private func copyRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copiar \(title)")
            }
        }
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Código QR de \(text)")
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
