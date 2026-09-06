import SwiftUI

struct SpringEndpointsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Spring Endpoints",
                systemImage: "point.3.connected.trianglepath.dotted",
                subtitle: "\(filteredEndpoints.count) routes",
                onMinimize: { model.workbenchFeature.setVisibility(.spring, isVisible: false) }
            )
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Filter route, controller, or method", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .litheWorkbenchSurface(LitheTheme.editor)
            if model.isIndexingSpring {
                ProgressView("Indexing Spring project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEndpoints.isEmpty {
                Text("No Spring MVC endpoints found")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredEndpoints) { endpoint in
                            Button { model.openSpringEndpoint(endpoint) } label: {
                                HStack(spacing: 9) {
                                    Text(endpoint.httpMethods.joined(separator: ","))
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(methodColor(endpoint.httpMethods.first))
                                        .frame(width: 58, alignment: .leading)
                                    Text(endpoint.route)
                                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    Text("\(endpoint.controller).\(endpoint.method)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                    Spacer()
                                    Text(model.relativePath(for: endpoint.url))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(LitheTheme.primaryText)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .lithePointer()
                        }
                    }
                    .padding(6)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var filteredEndpoints: [SpringEndpoint] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.springEndpoints }
        return model.springEndpoints.filter {
            [$0.route, $0.controller, $0.method, $0.httpMethods.joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    private func methodColor(_ method: String?) -> Color {
        switch method {
        case "GET": LitheTheme.success
        case "POST": LitheTheme.accent
        case "DELETE": LitheTheme.error
        default: LitheTheme.warning
        }
    }
}
