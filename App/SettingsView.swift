import SwiftUI

/// 占位设置界面。地基阶段仅提供最小可见内容，后续接入热键 / Provider / 听写配置。
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SayIt 设置")
                .font(.title2)
                .bold()
            Text("语音听写设置将在此处提供（热键、AI 润色、注入目标等）。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 260)
    }
}

#Preview {
    SettingsView()
}
