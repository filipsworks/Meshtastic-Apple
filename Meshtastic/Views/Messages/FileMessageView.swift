//
//  FileMessageView.swift
//  Meshtastic
//
//  A chat bubble for a file received/sent over the mesh (ha-bridge transfer
//  protocol). Shows the name + size and lets the user share/save the file.
//

import SwiftUI
import OSLog

struct FileMessageView: View {
	let message: MessageEntity
	let isCurrentUser: Bool

	@State private var exportURL: URL?

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: iconName)
				.font(.largeTitle)
				.foregroundColor(isCurrentUser ? .white : .accentColor)
			VStack(alignment: .leading, spacing: 2) {
				Text(message.fileName ?? "File")
					.font(.callout.bold())
					.lineLimit(1)
					.truncationMode(.middle)
				Text(sizeString)
					.font(.caption)
					.foregroundColor(isCurrentUser ? .white.opacity(0.8) : .secondary)
			}
			Spacer(minLength: 4)
			if let exportURL {
				ShareLink(item: exportURL) {
					Image(systemName: "square.and.arrow.up")
						.foregroundColor(isCurrentUser ? .white : .accentColor)
				}
			}
		}
		.padding(12)
		.foregroundColor(isCurrentUser ? .white : .primary)
		.background(isCurrentUser ? .accentColor : Color(.gray).opacity(0.3))
		.cornerRadius(15)
		.onAppear(perform: writeTempFile)
	}

	private var sizeString: String {
		ByteCountFormatter.string(fromByteCount: Int64(message.fileData?.count ?? 0), countStyle: .file)
	}

	private var iconName: String {
		let type = message.fileType ?? ""
		if type.hasPrefix("image") { return "photo" }
		if type.hasPrefix("audio") { return "waveform" }
		if type.hasPrefix("video") { return "film" }
		if type.contains("pdf") { return "doc.richtext" }
		return "doc.fill"
	}

	/// Stage the data as a temp file so ShareLink can export it with its name.
	private func writeTempFile() {
		guard exportURL == nil, let data = message.fileData else { return }
		let name = message.fileName ?? "file.bin"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
		do {
			try data.write(to: url)
			exportURL = url
		} catch {
			Logger.services.error("Failed to stage file for sharing: \(error.localizedDescription, privacy: .public)")
		}
	}
}
