//
//  MessageEntityExtension.swift
//  Meshtastic
//
//  Created by Ben on 8/22/23.
//

@preconcurrency import SwiftData
import CoreLocation
import Foundation
import MapKit
import SwiftUI

public struct PartialVoiceInfo: Codable {
	public let id: UInt16
	public let total: Int
	public var chunks: [Int: Data]
}

extension MessageEntity {
	/// Codec2 voice-message reassembly state, stored as a JSON blob in `audioData`
	/// (prefixed "PARTIAL_AUDIO:") until all chunks arrive; nil once complete.
	public var partialAudioInfo: PartialVoiceInfo? {
		guard let data = audioData else { return nil }
		if let prefix = "PARTIAL_AUDIO:".data(using: .utf8), data.count >= prefix.count, data.prefix(prefix.count) == prefix {
			let json = data.dropFirst(prefix.count)
			return try? JSONDecoder().decode(PartialVoiceInfo.self, from: json)
		}
		return nil
	}

	/// True once a full codec2 voice clip has been received and stored.
	public var isAudioMessage: Bool {
		return audioData != nil && !audioData!.isEmpty && partialAudioInfo == nil
	}

	/// True once a file received/sent over the mesh has been stored.
	public var isFileMessage: Bool {
		return fileData != nil && !fileData!.isEmpty
	}

	var hasTranslatedPayload: Bool {
		!(messagePayloadTranslated?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
	}

	var displayedPayload: String {
		if showTranslatedMessage, hasTranslatedPayload {
			return messagePayloadTranslated ?? messagePayload ?? "EMPTY MESSAGE"
		}
		return messagePayload ?? "EMPTY MESSAGE"
	}

	var displayedMarkdownPayload: String {
		if showTranslatedMessage, hasTranslatedPayload {
			return messagePayloadTranslatedMarkdown ?? messagePayloadTranslated ?? messagePayload ?? "EMPTY MESSAGE"
		}
		return messagePayloadMarkdown ?? messagePayload ?? "EMPTY MESSAGE"
	}

	var timestamp: Date {
		let time = messageTimestamp
		return Date(timeIntervalSince1970: TimeInterval(time))
	}

	var canRetry: Bool {
		let re = RoutingError(rawValue: Int(ackError))
		return re?.canRetry ?? false
	}

	@MainActor
	var tapbacks: [MessageEntity] {
		let context = PersistenceController.shared.context
		let msgId = self.messageId
		let descriptor = FetchDescriptor<MessageEntity>(
			predicate: #Predicate<MessageEntity> { msg in
				msg.replyID == msgId && msg.isEmoji == true
			},
			sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .forward)]
		)
		return (try? context.fetch(descriptor)) ?? []
	}

	func displayTimestamp(aboveMessage: MessageEntity?) -> Bool {
		if let aboveMessage = aboveMessage {
			return aboveMessage.timestamp.addingTimeInterval(3600) < timestamp  // 60 minutes
		}
		return false  // First message will have no timestamp
	}

	@MainActor
	func relayDisplay() -> String? {

		guard self.relayNode != 0 else { return nil }
		let context = PersistenceController.shared.context

		let relaySuffix = Int64(self.relayNode & 0xFF)
		let descriptor = FetchDescriptor<UserEntity>()

		guard let users = try? context.fetch(descriptor) else {
			return String(format: "Node 0x%02X", UInt32(self.relayNode & 0xFF))
		}
		let matchingUsers = users.filter { ($0.num & 0xFF) == relaySuffix }

		// If exactly one match is found, return its name
		if matchingUsers.count == 1, let name = matchingUsers.first?.longName, !name.isEmpty {
			return "\(name)"
		}

		// If no exact match, find the node with the smallest hopsAway
		if let closestNode = matchingUsers.min(by: { lhs, rhs in
			guard let lhsHops = lhs.userNode?.hopsAway,
				let rhsHops = rhs.userNode?.hopsAway
			else {
				return false
			}
			return lhsHops < rhsHops
		}), let name = closestNode.longName, !name.isEmpty {
			return "\(name)"
		}

		// Fallback to hex node number if no matches
		return String(format: "Node 0x%02X", UInt32(self.relayNode & 0xFF))
	}
}
