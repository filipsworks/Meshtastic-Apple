import SwiftUI
import OSLog
import UniformTypeIdentifiers

struct TextMessageField: View {
	static let maxbytes = 200
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@Environment(\.dismiss) var dismiss

	let destination: MessageDestination
	@Binding var replyMessageId: Int64
	@FocusState.Binding var isFocused: Bool
	/// Called on the main actor after a message is successfully sent, so the
	/// (poll-based) message list can reload immediately instead of waiting for
	/// the next refresh tick.
	var onMessageSent: (@MainActor () -> Void)?

	@State private var typingMessage: String = ""
	@State private var totalBytes = 0
	@State private var sendPositionWithMessage = false
	@StateObject private var audioManager = AudioManager.shared

	var body: some View {
		if #available(iOS 18.0, macOS 15.0, *) {
			FormattingComposeArea(
				typingMessage: $typingMessage,
				totalBytes: $totalBytes,
				replyMessageId: $replyMessageId,
				isFocused: $isFocused,
				maxbytes: Self.maxbytes,
				onSend: sendMessage,
				onAlert: { typingMessage += "🔔 Alert Bell Character! \u{7}" },
				onRequestPosition: requestPosition,
				onSendAudio: sendAudioMessage,
				onSendFile: { data, name, type in sendFileMessage(fileData: data, fileName: name, contentType: type) }
			)
		} else {
			VStack(spacing: 0) {
				HStack(alignment: .top) {
					if replyMessageId != 0 || isFocused {
						Button {
							withAnimation(.easeInOut(duration: 0.2)) {
								replyMessageId = 0
							}
							isFocused = false
						} label: {
							Image(systemName: "x.circle.fill")
								.font(.largeTitle)
							}
							if replyMessageId != 0 {
								Text("Reply")
									.padding(.top, 10)
							}
						}
						TextField("Message", text: $typingMessage, axis: .vertical)
							.frame(minHeight: 36)
							.padding(.horizontal, 16)
							.padding(.vertical, 12)
							.background(
								RoundedRectangle(cornerRadius: 20)
									.strokeBorder(.tertiary, lineWidth: 1)
									.background(RoundedRectangle(cornerRadius: 20).fill(Color(.systemBackground)))
							)
							.contentShape(RoundedRectangle(cornerRadius: 20))
							.onChange(of: typingMessage) { _, value in
								totalBytes = value.utf8.count
								while totalBytes > Self.maxbytes {
									typingMessage = String(typingMessage.dropLast())
									totalBytes = typingMessage.utf8.count
								}
							}
							.keyboardType(.default)
							.focused($isFocused)
							.multilineTextAlignment(.leading)
							.onSubmit {
#if targetEnvironment(macCatalyst)
								sendMessage()
#endif
							}
							.foregroundColor(.primary)
						if audioManager.isRecording {
							HStack {
								Text(timeString(time: audioManager.recordingDuration))
									.foregroundColor(.red)
									.font(.headline)
								Spacer()
								Button(action: {
									audioManager.cancelRecording()
								}) {
									Image(systemName: "trash.circle.fill")
										.font(.largeTitle)
										.foregroundColor(.red)
								}
								Button(action: sendAudioMessage) {
									Image(systemName: "arrow.up.circle.fill")
										.font(.largeTitle)
										.foregroundColor(.accentColor)
								}
							}
							.padding(.leading, 10)
						} else if !typingMessage.isEmpty {
							Button(action: sendMessage) {
								Image(systemName: "arrow.up.circle.fill")
									.font(.largeTitle)
									.foregroundColor(.accentColor)
							}
						} else {
							Button(action: {
								audioManager.startRecording()
							}) {
								Image(systemName: "mic.circle.fill")
									.font(.largeTitle)
									.foregroundColor(.accentColor)
							}
						}
					}
					.padding(15)
					if isFocused {
						if #available(iOS 26.0, macOS 26.0, *) {
							legacyToolbarContent
								.padding(.vertical, 8)
								.padding(.horizontal)
								.background(.ultraThinMaterial, in: Capsule())
							Spacer()
								.frame(height: 10)
						} else {
							Divider()
							legacyToolbarContent
								.padding(.horizontal, 15)
								.padding(.vertical, 10)
								.background(.bar)
						}
					}
			}
		}
	}

	private var legacyToolbarContent: some View {
		HStack {
			Spacer()
			#if targetEnvironment(macCatalyst)
			Button {
				if let nsApp = NSClassFromString("NSApplication")?.value(forKeyPath: "sharedApplication") as? NSObject {
					let selector = NSSelectorFromString("orderFrontCharacterPalette:")
					if nsApp.responds(to: selector) {
						nsApp.perform(selector, with: nil)
					}
				}
			} label: {
				Image(systemName: "face.smiling")
			}
			Spacer()
			#endif
			AlertButton { typingMessage += "🔔 Alert Bell Character! \u{7}" }
			Spacer()
			RequestPositionButton(action: requestPosition)
			Spacer()
			TextMessageSize(maxbytes: Self.maxbytes, totalBytes: totalBytes)
		}
	}

	private func requestPosition() {
		let userLongName = accessoryManager.activeConnection?.device.longName ?? "Unknown"
		sendPositionWithMessage = true
		typingMessage = "📍 " + userLongName + " \(destination.positionShareMessage)."
	}

	private func sendMessage() {
		Task {
			do {
				try await accessoryManager.sendMessage(
					message: typingMessage,
					toUserNum: destination.userNum,
					channel: destination.channelNum,
					isEmoji: false,
					replyID: replyMessageId)

				typingMessage = ""
				isFocused = false
				replyMessageId = 0

				if sendPositionWithMessage {
					try await accessoryManager.sendPosition(
						channel: destination.channelNum,
						destNum: destination.positionDestNum,
						wantResponse: destination.wantPositionResponse
					)
					Logger.mesh.info("Location Sent")
				}

				await MainActor.run { onMessageSent?() }
			} catch {
				Logger.mesh.info("Error sending message")
			}
		}
	}

	private func sendAudioMessage() {
		guard let audioData = audioManager.stopRecordingAndEncode() else { return }
		Task {
			do {
				try await accessoryManager.sendAudioMessage(
					audioData: audioData,
					toUserNum: destination.userNum,
					channel: destination.channelNum,
					replyID: replyMessageId
				)
				replyMessageId = 0
			} catch {
				Logger.mesh.error("Error sending audio message: \(error)")
			}
		}
	}

	private func sendFileMessage(fileData: Data, fileName: String, contentType: String) {
		Task {
			do {
				try await accessoryManager.sendFileMessage(
					fileData: fileData,
					fileName: fileName,
					contentType: contentType,
					toUserNum: destination.userNum,
					channel: destination.channelNum,
					replyID: replyMessageId
				)
				replyMessageId = 0
			} catch {
				Logger.mesh.error("Error sending file message: \(error)")
			}
		}
	}

	private func timeString(time: TimeInterval) -> String {
		let minutes = Int(time) / 60 % 60
		let seconds = Int(time) % 60
		return String(format: "%02i:%02i", minutes, seconds)
	}
}

// MARK: - FormattingComposeArea

@available(iOS 18.0, macOS 15.0, *)
private struct FormattingComposeArea: View {
	@Binding var typingMessage: String
	@Binding var totalBytes: Int
	@Binding var replyMessageId: Int64
	@FocusState.Binding var isFocused: Bool
	let maxbytes: Int
	let onSend: () -> Void
	let onAlert: () -> Void
	let onRequestPosition: () -> Void
	let onSendAudio: () -> Void
	let onSendFile: (Data, String, String) -> Void

	@StateObject private var audioManager = AudioManager.shared
	@State private var textSelection: TextSelection?
	@State private var showToolbar = false
	@State private var showLinkSheet = false
	@State private var showFileImporter = false

	private func timeString(time: TimeInterval) -> String {
		let minutes = Int(time) / 60 % 60
		let seconds = Int(time) % 60
		return String(format: "%02i:%02i", minutes, seconds)
	}

	private func handleFilePick(_ result: Result<[URL], Error>) {
		guard case .success(let urls) = result, let url = urls.first else { return }
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		guard let data = try? Data(contentsOf: url) else { return }
		let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
		onSendFile(data, url.lastPathComponent, type)
	}

	var body: some View {
		VStack(spacing: 0) {
			MessagePreview(text: typingMessage)
			HStack(alignment: .top) {
				if replyMessageId != 0 || isFocused {
					Button {
						withAnimation(.easeInOut(duration: 0.2)) {
							replyMessageId = 0
						}
						isFocused = false
					} label: {
						Image(systemName: "x.circle.fill")
							.font(.largeTitle)
					}
					if replyMessageId != 0 {
						Text("Reply")
							.padding(.top, 10)
					}
				}
				TextEditor(text: $typingMessage, selection: $textSelection)
					.frame(minHeight: 36, maxHeight: 200)
					.padding(.horizontal, 16)
					.padding(.vertical, 4)
					.scrollContentBackground(.hidden)
					.background(
						RoundedRectangle(cornerRadius: 20)
							.strokeBorder(.tertiary, lineWidth: 1)
							.background(RoundedRectangle(cornerRadius: 20).fill(Color(.systemBackground)))
					)
					.contentShape(RoundedRectangle(cornerRadius: 20))
					.onChange(of: typingMessage) { _, value in
						totalBytes = value.utf8.count
						while totalBytes > maxbytes {
							typingMessage = String(typingMessage.dropLast())
							totalBytes = typingMessage.utf8.count
						}
					}
					.keyboardType(.default)
					.focused($isFocused)
					.multilineTextAlignment(.leading)
					.foregroundColor(.primary)
				if audioManager.isRecording {
					HStack {
						Text(timeString(time: audioManager.recordingDuration))
							.foregroundColor(.red)
							.font(.headline)
						Spacer()
						Button(action: { audioManager.cancelRecording() }) {
							Image(systemName: "trash.circle.fill")
								.font(.largeTitle)
								.foregroundColor(.red)
						}
						Button(action: onSendAudio) {
							Image(systemName: "arrow.up.circle.fill")
								.font(.largeTitle)
								.foregroundColor(.accentColor)
						}
					}
					.padding(.leading, 10)
				} else if !typingMessage.isEmpty {
					Button(action: onSend) {
						Image(systemName: "arrow.up.circle.fill")
							.font(.largeTitle)
							.foregroundColor(.accentColor)
					}
				} else {
					Button(action: { audioManager.startRecording() }) {
						Image(systemName: "mic.circle.fill")
							.font(.largeTitle)
							.foregroundColor(.accentColor)
					}
				}
			}
			.padding(15)
			if showToolbar {
				if #available(iOS 26.0, macOS 26.0, *) {
					toolbarContent
						.padding(.vertical, 8)
						.padding(.horizontal)
						.background(.ultraThinMaterial, in: Capsule())
					Spacer()
						.frame(height: 10)
				} else {
					Divider()
					toolbarContent
						.padding(.horizontal, 15)
						.padding(.vertical, 6)
						.background(.bar)
				}
			}
		}
		.onChange(of: isFocused) { _, focused in
			if focused {
				showToolbar = true
			} else {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
					if !isFocused && !showLinkSheet {
						showToolbar = false
					}
				}
			}
		}
		#if targetEnvironment(macCatalyst)
		.onKeyPress(.return, phases: .down) { keyPress in
			if keyPress.modifiers.contains(.shift) {
				return .ignored
			}
			onSend()
			return .handled
		}
		#endif
	}

	private var toolbarContent: some View {
		HStack {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack {
					if typingMessage.count >= 3 {
						FormattingToolbarButtons(typingMessage: $typingMessage, textSelection: $textSelection, showLinkAlert: $showLinkSheet)
					}
					#if targetEnvironment(macCatalyst)
					Button {
						if let nsApp = NSClassFromString("NSApplication")?.value(forKeyPath: "sharedApplication") as? NSObject {
							let selector = NSSelectorFromString("orderFrontCharacterPalette:")
							if nsApp.responds(to: selector) {
								nsApp.perform(selector, with: nil)
							}
						}
					} label: {
						Image(systemName: "face.smiling")
					}
					#endif
					AlertButton(action: onAlert, compact: true)
					RequestPositionButton(action: onRequestPosition, compact: true)
						Button { showFileImporter = true } label: {
							Image(systemName: "paperclip")
						}
						.fileImporter(isPresented: $showFileImporter,
									  allowedContentTypes: [.data, .item],
									  allowsMultipleSelection: false) { result in
							handleFilePick(result)
						}
				}
			}
			Spacer()
			TextMessageSize(maxbytes: maxbytes, totalBytes: totalBytes, compact: true)
		}
	}
}

private extension MessageDestination {
	var positionShareMessage: String {
		switch self {
		case .user: return "has shared their position and requested a response with your position"
		case .channel: return "has shared their position with you"
		}
	}

	var positionDestNum: Int64 {
		switch self {
		case let .user(user): return user.num
		case .channel: return Int64(Constants.maximumNodeNum)
		}
	}

	var wantPositionResponse: Bool {
		switch self {
		case .user: return true
		case .channel: return false
		}
	}
}
