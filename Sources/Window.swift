import SwiftUI

struct DongbaWindow: View {
    @ObservedObject var controller: AppDelegate
    @ObservedObject var location: LocationModel
    var body: some View {
        TabView(selection: $controller.activePanel) {
            LocationPane(model: location)
                .tabItem { Label("系统定位", systemImage: "mappin.and.ellipse") }.tag(MainPanel.location)
            PreferencesPane(controller: controller)
                .tabItem { Label("时区与外观", systemImage: "clock") }.tag(MainPanel.preferences)
        }
        .padding(.top, 8)
        .frame(minWidth: 960, minHeight: 700)
    }
}

// Select the public property-wrapper type explicitly. The current command-line
// SDK also exports a State macro but does not ship its SwiftUIMacros plugin.
// Remove this alias once the command-line tools include that plugin.
private typealias TimeZoneDraftState = SwiftUICore.State<String>

private struct PreferencesPane: View {
    @ObservedObject var controller: AppDelegate
    @TimeZoneDraftState private var actualDraft = ""
    @TimeZoneDraftState private var systemDraft = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("时区与外观").font(.title.weight(.semibold))
                    Text("实际时区用于菜单栏时钟和日出日落；系统时区用于 Mac 的系统时钟。")
                        .foregroundStyle(.secondary)
                }
                GroupBox("当前时间") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("实际", value: controller.actualClockText)
                        LabeledContent("系统", value: controller.systemClockText)
                        Text(controller.timeDifferenceText).font(.callout).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("实际时区") {
                    VStack(alignment: .leading, spacing: 10) {
                        zoneMenu(selection: $actualDraft)
                        Text("菜单栏时钟和自动外观按这个时区计算。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("应用实际时区") { controller.changeActualZone(actualDraft) }
                            .disabled(actualDraft == controller.actualZoneIdentifier || actualDraft.isEmpty)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("系统时区（伪装）") {
                    VStack(alignment: .leading, spacing: 10) {
                        zoneMenu(selection: $systemDraft)
                        Text("会修改 Mac 系统时钟，需要管理员认证。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("修改系统时区") { controller.changeSystemZone(systemDraft) }
                            .disabled(systemDraft == controller.systemZoneIdentifier || systemDraft.isEmpty)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("系统外观") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("外观", selection: Binding(get: { controller.appearanceControl }, set: { controller.selectAppearanceControl($0) })) {
                            ForEach(AppearanceControl.allCases) { control in Text(control.label).tag(control) }
                        }.pickerStyle(.segmented)
                        Text(controller.appearanceDescription).font(.callout).foregroundStyle(.secondary)
                    }.padding(10)
                }
                Toggle("登录时启动GeoShift", isOn: Binding(get: { controller.loginEnabled }, set: { controller.setLoginEnabled($0) }))
                if let error = controller.settingsError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 670, alignment: .leading).padding(34)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { refreshDrafts() }
        .onChange(of: controller.actualZoneIdentifier) { actualDraft = controller.actualZoneIdentifier }
        .onChange(of: controller.systemZoneIdentifier) { systemDraft = controller.systemZoneIdentifier }
    }

    private func refreshDrafts() {
        actualDraft = controller.actualZoneIdentifier
        systemDraft = controller.systemZoneIdentifier
    }

    private func zoneMenu(selection: Binding<String>) -> some View {
        Menu {
            ForEach(controller.availableZones, id: \.key) { group in
                Menu(group.title) {
                    ForEach(group.zones, id: \.identifier) { zone in
                        Button(zone.title) { selection.wrappedValue = zone.identifier }
                    }
                }
            }
        } label: {
            Text(ZoneCatalog.title(for: selection.wrappedValue, at: Date()))
                .frame(maxWidth: .infinity, alignment: .leading)
        }.menuStyle(.borderlessButton)
    }
}
