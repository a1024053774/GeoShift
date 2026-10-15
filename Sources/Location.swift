import AppKit
import CoreLocation
import Foundation
import MapKit
import SwiftUI

struct HelperReply: Decodable {
    let success: Bool
    let changed: Bool?
    let message: String
}

struct PlaceResult: Decodable {
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    private enum CodingKeys: String, CodingKey { case name, address = "display_name", latitude = "lat", longitude = "lon" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        address = try values.decode(String.self, forKey: .address)
        let latitude = try values.decode(String.self, forKey: .latitude)
        let longitude = try values.decode(String.self, forKey: .longitude)
        guard let lat = Double(latitude), let lon = Double(longitude),
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: values, debugDescription: "搜索结果包含无效坐标。")
        }
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

@MainActor
final class LocationModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var latitude = ""
    @Published var longitude = ""
    @Published var searchText = ""
    @Published var results: [PlaceResult] = []
    @Published var camera: MapCameraPosition = .automatic
    @Published var currentLocation: CLLocation?
    @Published var message = "在地图点选位置，或输入坐标。"
    @Published var busy = false
    @Published var searching = false
    @Published var verified = false
    @Published var hasApplied = false
    @Published var hasError = false
    private var searchCache: [String: [PlaceResult]] = [:]
    private var lastSearchAt = Date.distantPast
    private let manager = CLLocationManager()
    private var pendingPoint: CLLocation?
    private var pendingRestore = false
    private var operationStarted = Date.distantFuture
    private var initialCameraSet = false
    private var readingStarted = false
    private var appliedPoint: CLLocation?

    var selectedCoordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var coordinateError: String? {
        if (!latitude.isEmpty || !longitude.isEmpty) && selectedCoordinate == nil {
            return "纬度须在 −90～90，经度须在 −180～180。"
        }
        return nil
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        if let saved = UserDefaults.standard.array(forKey: "selectedCoordinate") as? [Double], saved.count == 2 {
            select(CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1]), center: true)
        }
    }

    func startReading() {
        guard !readingStarted else { return }
        readingStarted = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if readingStarted && manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func select(_ point: CLLocationCoordinate2D, center: Bool) {
        latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude)
        longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.longitude)
        hasError = false
        verified = false
        let prefix = hasApplied ? "已选新位置" : "已选位置"
        message = String(format: "%@：%.6f, %.6f。点击%@系统定位。", locale: Locale(identifier: "zh_CN"),
            prefix, point.latitude, point.longitude, hasApplied ? "更新" : "设置")
        if center {
            camera = .region(MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
            initialCameraSet = true
        }
    }

    func centerSelection() {
        if let point = selectedCoordinate { select(point, center: true) }
    }

    func centerSystemLocation() {
        guard let currentLocation else { return }
        camera = .region(MKCoordinateRegion(center: currentLocation.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
        initialCameraSet = true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        if currentLocation == nil && operationStarted == Date.distantFuture {
            hasError = false
            message = "在地图点选位置，或输入坐标。"
        }
        currentLocation = latest
        if !initialCameraSet { centerSystemLocation() }
        verifyLatest()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as NSError).code == CLError.denied.rawValue && currentLocation == nil && !busy {
            message = "请在系统设置中允许 GeoShift读取位置，以核验系统读数。"
            hasError = true
        }
    }

    private func verifyLatest() {
        guard let currentLocation, currentLocation.timestamp >= operationStarted.addingTimeInterval(-1) else { return }
        if let pendingPoint, currentLocation.distance(from: pendingPoint) <= 25 {
            verified = true
            hasError = false
            message = "系统定位已到达所选位置。"
            self.pendingPoint = nil
        } else if pendingRestore {
            verified = true
            hasError = false
            message = "原配置已恢复，已收到新的系统定位。"
            pendingRestore = false
        } else if verified, let appliedPoint, hasApplied,
                  currentLocation.distance(from: appliedPoint) > 25 {
            verified = false
            message = "当前系统坐标与已应用的位置不一致，请核对或重新设置。"
        }
    }

    func selectionDidChange() {
        guard !busy else { return }
        verified = false
        hasError = false
        if selectedCoordinate == nil { message = "请输入有效坐标。" }
        else { message = hasApplied ? "新位置尚未应用，点击更新系统定位。" : "位置已选择，点击设置系统定位。" }
    }

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searching else { return }
        let endpoint = UserDefaults.standard.string(forKey: "geocodingEndpoint") ?? "https://nominatim.openstreetmap.org/search"
        let cacheKey = endpoint + "|" + query
        if let cached = searchCache[cacheKey] { results = cached; return }
        guard var components = URLComponents(string: endpoint), components.scheme == "https", components.host != nil else {
            message = "地名搜索服务地址无效。"; hasError = true; return
        }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "6"), URLQueryItem(name: "accept-language", value: "zh-CN,en")]
        guard let url = components.url else { message = "无法创建搜索请求。"; hasError = true; return }
        searching = true
        results = []
        Task {
            defer { searching = false }
            do {
                // The public service permits only manual searches, at most one per second.
                let delay = 1 - Date().timeIntervalSince(lastSearchAt)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.setValue("GeoShift/2.0 (macOS location utility)", forHTTPHeaderField: "User-Agent")
                lastSearchAt = Date()
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "PlaceSearch", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: "地名搜索服务暂时不可用。"])
                }
                results = try JSONDecoder().decode([PlaceResult].self, from: data)
                searchCache[cacheKey] = results
                hasError = false
                if results.isEmpty { message = "没有找到地点，请换个名称或直接输入坐标。" }
            } catch {
                message = "地点搜索失败：\(error.localizedDescription)"
                hasError = true
            }
        }
    }

    func applySelection() {
        guard let point = selectedCoordinate, !busy else { return }
        camera = .region(MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
        initialCameraSet = true
        UserDefaults.standard.set([point.latitude, point.longitude], forKey: "selectedCoordinate")
        perform(["action": "set", "latitude": point.latitude, "longitude": point.longitude], point: point)
    }

    func restoreOriginal() {
        guard !busy else { return }
        perform(["action": "restore"], point: nil)
    }

    private func perform(_ request: [String: Any], point: CLLocationCoordinate2D?) {
        guard let script = Bundle.main.path(forResource: "system_location", ofType: "py"),
              let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let requestText = String(data: data, encoding: .utf8) else {
            message = "应用文件不完整，请重新构建应用。"
            hasError = true
            return
        }
        busy = true
        verified = false
        hasError = false
        pendingPoint = nil
        pendingRestore = false
        operationStarted = Date()
        message = point == nil ? "正在恢复系统定位…" : "正在设置系统定位…"
        DispatchQueue.global(qos: .userInitiated).async {
            var authorizationStatus: Int32 = 0
            let raw = script.withCString { scriptPointer in
                requestText.withCString { requestPointer in
                    execute_location_request(scriptPointer, requestPointer, &authorizationStatus)
                }
            }
            let response = raw.map { String(cString: $0) }
            if let raw { free(raw) }
            let authorizationCode = authorizationStatus
            DispatchQueue.main.async {
                self.busy = false
                if authorizationCode != 0 {
                    self.message = authorizationCode == -60006 ? "已取消管理员认证。" : "管理员认证失败（\(authorizationCode)）。"
                    self.hasError = true
                    return
                }
                guard let response, let data = response.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(HelperReply.self, from: data) else {
                    self.message = "未收到有效的操作结果。请点击恢复，核对系统定位。"
                    self.hasError = true
                    return
                }
                self.message = reply.message
                if !reply.success { self.hasError = true; return }
                if reply.changed == true {
                    if let point {
                        self.hasApplied = true
                        self.appliedPoint = CLLocation(latitude: point.latitude, longitude: point.longitude)
                        self.pendingPoint = self.appliedPoint
                        self.message = "配置已应用，等待系统定位核验…"
                    } else {
                        self.hasApplied = false
                        self.appliedPoint = nil
                        self.pendingRestore = true
                        self.message = "原配置已恢复，等待新定位读数…"
                    }
                    self.verifyLatest()
                }
            }
        }
    }
}

// The command-line macOS 27 SDK exposes SwiftUI.State as a macro but omits
// its plugin; use the public SwiftUICore property-wrapper spelling here.
private typealias MapPressDateState = SwiftUICore.State<Date?>
private typealias MapPressPointState = SwiftUICore.State<CGPoint?>
private typealias MapPressBoolState = SwiftUICore.State<Bool>

struct LocationPane: View {
    @ObservedObject var model: LocationModel
    @MapPressDateState private var mapPressStartedAt: Date?
    @MapPressPointState private var mapPressStartLocation: CGPoint?
    @MapPressBoolState private var mapPressMoved = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择位置").font(.title2.weight(.semibold))
                    Text("地图上的红色标记是所选位置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("搜索地点或地址", text: $model.searchText)
                        .textFieldStyle(.roundedBorder).onSubmit { model.search() }
                        .accessibilityIdentifier("place-search")
                        .disabled(model.busy)
                    Button { model.search() } label: {
                        if model.searching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass") }
                    }.help("搜索地点").disabled(model.busy || model.searching || model.searchText.isEmpty)
                }
                Link("地名搜索 © OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.caption).help("搜索词发送到全球地名搜索服务；系统定位不会随搜索发送。")
                if !model.results.isEmpty {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { _, item in
                            Button {
                                model.select(item.coordinate, center: true)
                                model.results = []
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).fontWeight(.medium)
                                    Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                    }.frame(maxHeight: 180)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("所选坐标").font(.headline)
                    coordinateField("纬度", text: $model.latitude, identifier: "latitude-field")
                    coordinateField("经度", text: $model.longitude, identifier: "longitude-field")
                    if let error = model.coordinateError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button("在地图中显示所选位置") { model.centerSelection() }
                        .buttonStyle(.link).disabled(model.selectedCoordinate == nil)
                }
                Button(model.hasApplied ? "更新系统定位" : "设置系统定位") { model.applySelection() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity).disabled(model.busy || model.selectedCoordinate == nil)
                    .accessibilityIdentifier("apply-location")
                Button("恢复真实定位") { model.restoreOriginal() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .frame(maxWidth: .infinity).disabled(model.busy)
                    .accessibilityIdentifier("restore-location")
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.hasError ? "exclamationmark.circle" : model.verified ? "checkmark.circle.fill" : "location.circle")
                        .foregroundStyle(model.hasError ? Color.orange : model.verified ? Color.green : Color.secondary) }
                    Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("operation-status")
                }
                Spacer(minLength: 0)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("当前系统定位").font(.headline)
                    if let location = model.currentLocation {
                        Text(String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude, location.coordinate.longitude))
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("system-coordinate")
                        Text("精度约 \(Int(location.horizontalAccuracy)) 米").font(.caption).foregroundStyle(.secondary)
                    } else { Text("等待定位读数…").foregroundStyle(.secondary) }
                    Button("在地图中显示系统定位") { model.centerSystemLocation() }
                        .buttonStyle(.link).disabled(model.currentLocation == nil)
                }
                Text("修改定位需要管理员认证。关闭窗口后设置会保留；结束时请点击恢复。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(width: 325).frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack(alignment: .topLeading) {
                MapReader { proxy in
                    Map(position: $model.camera) {
                        UserAnnotation()
                        if let point = model.selectedCoordinate {
                            Annotation("已选位置", coordinate: point, anchor: .bottom) {
                                VStack(spacing: 1) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 30, weight: .bold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .red)
                                        .shadow(radius: 2)
                                    Text("已选位置")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                    .mapStyle(.standard)
                    .mapControls { MapCompass(); MapScaleView() }
                    .simultaneousGesture(SpatialTapGesture().onEnded { event in
                        if let point = proxy.convert(event.location, from: .local), !model.busy {
                            model.select(point, center: false)
                        }
                    })
                    // MapKit owns panning and zooming. A zero-distance drag observes
                    // the same pointer stream without replacing those map gestures;
                    // a press becomes a location pick only after it stays still.
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if mapPressStartedAt == nil {
                                mapPressStartedAt = value.time
                                mapPressStartLocation = value.startLocation
                                mapPressMoved = false
                            }
                            if hypot(value.translation.width, value.translation.height) > 24 {
                                mapPressMoved = true
                            }
                        }
                        .onEnded { value in
                            defer {
                                mapPressStartedAt = nil
                                mapPressStartLocation = nil
                                mapPressMoved = false
                            }
                            guard let startedAt = mapPressStartedAt,
                                  let startLocation = mapPressStartLocation,
                                  !mapPressMoved,
                                  value.time.timeIntervalSince(startedAt) >= 0.35,
                                  !model.busy,
                                  let point = proxy.convert(startLocation, from: .local) else { return }
                            model.select(point, center: false)
                        })
                    .disabled(model.busy)
                    .accessibilityIdentifier("location-map")
                }
                if let point = model.selectedCoordinate {
                    Label {
                        Text(String(format: "已选 %.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                    } icon: {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.red)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.red.opacity(0.35), lineWidth: 1))
                    .padding(14)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("selected-location-badge")
                }
            }
        }
        .frame(minWidth: 960, minHeight: 650)
        .onChange(of: model.latitude) { model.selectionDidChange() }
        .onChange(of: model.longitude) { model.selectionDidChange() }
    }

    private func coordinateField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title).frame(width: 38, alignment: .leading)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced)).accessibilityIdentifier(identifier)
                .disabled(model.busy)
                .onSubmit { model.centerSelection() }
        }
    }
}
