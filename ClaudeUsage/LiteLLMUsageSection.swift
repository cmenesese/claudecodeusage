import SwiftUI

/// LiteLLM spend section for the popover, matching the visual language of
/// `AccountUsageSection` in UsageView.swift.
struct LiteLLMUsageSection: View {
    @ObservedObject var manager: LiteLLMManager
    let onOpenSettings: () -> Void
    @Environment(\.openURL) var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LITELLM")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if !LiteLLMConfig.shared.isConfigured {
                emptyStateView()
            } else if let error = manager.error {
                errorView(error)
            } else if let spend = manager.spend {
                spendContent(spend)
            } else {
                loadingView()
            }
        }
    }

    @ViewBuilder
    private func spendContent(_ spend: LiteLLMSpendData) -> some View {
        VStack(spacing: 16) {
            if let maxBudget = spend.maxBudget {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Budget")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(spend.budgetDuration.map { "Current \($0) period" } ?? "Current period")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("$\(String(format: "%.2f", spend.spend))")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(colorForPercentage(spend.percentage))
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.separatorColor))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(colorForPercentage(spend.percentage))
                                .frame(width: geometry.size.width * CGFloat(min(spend.percentage, 100)) / 100, height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("of $\(String(format: "%.2f", maxBudget)) limit")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let resetsAt = spend.budgetResetAt {
                            Text("resets \(resetsAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            if let activity = manager.dailyActivity {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Today")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("$\(String(format: "%.2f", activity.spend))")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("\(activity.totalTokens) tokens")
                        Spacer()
                        Text("\(activity.successfulRequests) ok · \(activity.failedRequests) failed")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func emptyStateView() -> some View {
        VStack(spacing: 8) {
            Text("LiteLLM is not configured")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Settings") {
                onOpenSettings()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func loadingView() -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading LiteLLM spend…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private func colorForPercentage(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}
