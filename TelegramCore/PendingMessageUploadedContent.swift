import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

enum PendingMessageUploadedContent {
    case text(String)
    case media(Api.InputMedia)
    case forward(ForwardSourceInfoAttribute)
    case chatContextResult(OutgoingChatContextResultMessageAttribute)
    case secretMedia(Api.InputEncryptedFile, Int32, SecretFileEncryptionKey)
}

enum PendingMessageUploadedContentResult {
    case progress(Float)
    case content(PendingMessageUploadedContent)
}

enum PendingMessageUploadError {
    case generic
}

enum PendingMessageUploadContent {
    case ready(PendingMessageUploadedContent)
    case upload(Signal<PendingMessageUploadedContentResult, PendingMessageUploadError>)
}

func messageContentToUpload(network: Network, postbox: Postbox, transformOutgoingMessageMedia: TransformOutgoingMessageMedia?, message: Message) -> PendingMessageUploadContent {
    return messageContentToUpload(network: network, postbox: postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, peerId: message.id.peerId, messageId: message.id, attributes: message.attributes, text: message.text, media: message.media)
}

func messageContentToUpload(network: Network, postbox: Postbox, transformOutgoingMessageMedia: TransformOutgoingMessageMedia?, peerId: PeerId, messageId: MessageId?, attributes: [MessageAttribute], text: String, media: [Media]) -> PendingMessageUploadContent {
    var contextResult: OutgoingChatContextResultMessageAttribute?
    var autoremoveAttribute: AutoremoveTimeoutMessageAttribute?
    for attribute in attributes {
        if let attribute = attribute as? OutgoingChatContextResultMessageAttribute {
            contextResult = attribute
        } else if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
            autoremoveAttribute = attribute
        }
    }
    
    var forwardInfo: ForwardSourceInfoAttribute?
    for attribute in attributes {
        if let attribute = attribute as? ForwardSourceInfoAttribute {
            forwardInfo = attribute
        }
    }
    
    if let forwardInfo = forwardInfo {
        return .ready(.forward(forwardInfo))
    }
    
    if let forwardInfo = forwardInfo {
        return .ready(.forward(forwardInfo))
    } else if let contextResult = contextResult {
        return .ready(.chatContextResult(contextResult))
    } else if let media = media.first {
        if let image = media as? TelegramMediaImage, let _ = largestImageRepresentation(image.representations) {
            return .upload(uploadedMediaImageContent(network: network, postbox: postbox, peerId: peerId, image: image, text: text, autoremoveAttribute: autoremoveAttribute))
        } else if let file = media as? TelegramMediaFile {
            if let resource = file.resource as? CloudDocumentMediaResource {
                return .ready(.media(Api.InputMedia.inputMediaDocument(id: Api.InputDocument.inputDocument(id: resource.fileId, accessHash: resource.accessHash), caption: text)))
            } else {
                return .upload(uploadedMediaFileContent(network: network, postbox: postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, peerId: peerId, messageId: messageId, text: text, attributes: attributes, file: file))
            }
        } else if let contact = media as? TelegramMediaContact {
            let input = Api.InputMedia.inputMediaContact(phoneNumber: contact.phoneNumber, firstName: contact.firstName, lastName: contact.lastName)
            return .ready(.media(input))
        } else if let map = media as? TelegramMediaMap {
            let input: Api.InputMedia
            if let venue = map.venue {
                input = .inputMediaVenue(geoPoint: Api.InputGeoPoint.inputGeoPoint(lat: map.latitude, long: map.longitude), title: venue.title, address: venue.address ?? "", provider: venue.provider ?? "", venueId: venue.id ?? "", venueType: venue.type ?? "")
            } else {
                input = .inputMediaGeoPoint(geoPoint: Api.InputGeoPoint.inputGeoPoint(lat: map.latitude, long: map.longitude))
            }
            return .ready(.media(input))
        } else {
            return .ready(.text(text))
        }
    } else {
        return .ready(.text(text))
    }
}

private func uploadedMediaImageContent(network: Network, postbox: Postbox, peerId: PeerId, image: TelegramMediaImage, text: String, autoremoveAttribute: AutoremoveTimeoutMessageAttribute?) -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> {
    if let largestRepresentation = largestImageRepresentation(image.representations) {
        return multipartUpload(network: network, postbox: postbox, source: .resource(largestRepresentation.resource), encrypt: peerId.namespace == Namespaces.Peer.SecretChat, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
            |> mapError { _ -> PendingMessageUploadError in return .generic }
            |> map { next -> PendingMessageUploadedContentResult in
                switch next {
                    case let .progress(progress):
                        return .progress(progress)
                    case let .inputFile(file):
                        var flags: Int32 = 0
                        var ttlSeconds: Int32?
                        if let autoremoveAttribute = autoremoveAttribute {
                            flags |= 1 << 1
                            ttlSeconds = autoremoveAttribute.timeout
                        }
                        return .content(.media(Api.InputMedia.inputMediaUploadedPhoto(flags: flags, file: file, caption: text, stickers: nil, ttlSeconds: ttlSeconds)))
                    case let .inputSecretFile(file, size, key):
                        return .content(.secretMedia(file, size, key))
                }
            }
    } else {
        return .single(.content(.text(text)))
    }
}

func inputDocumentAttributesFromFileAttributes(_ fileAttributes: [TelegramMediaFileAttribute]) -> [Api.DocumentAttribute] {
    var attributes: [Api.DocumentAttribute] = []
    for attribute in fileAttributes {
        switch attribute {
            case .Animated:
                attributes.append(.documentAttributeAnimated)
            case let .FileName(fileName):
                attributes.append(.documentAttributeFilename(fileName: fileName))
            case let .ImageSize(size):
                attributes.append(.documentAttributeImageSize(w: Int32(size.width), h: Int32(size.height)))
            case let .Sticker(displayText, packReference, maskCoords):
                var stickerSet: Api.InputStickerSet = .inputStickerSetEmpty
                var flags: Int32 = 0
                if let packReference = packReference {
                    switch packReference {
                        case let .id(id, accessHash):
                            stickerSet = .inputStickerSetID(id: id, accessHash: accessHash)
                        case let .name(name):
                            stickerSet = .inputStickerSetShortName(shortName: name)
                    }
                }
                var inputMaskCoords: Api.MaskCoords?
                if let maskCoords = maskCoords {
                    flags |= 1 << 0
                    inputMaskCoords = .maskCoords(n: maskCoords.n, x: maskCoords.x, y: maskCoords.y, zoom: maskCoords.zoom)
                }
                attributes.append(.documentAttributeSticker(flags: flags, alt: displayText, stickerset: stickerSet, maskCoords: inputMaskCoords))
            case .HasLinkedStickers:
                attributes.append(.documentAttributeHasStickers)
            case let .Video(duration, size, videoFlags):
                var flags: Int32 = 0
                if videoFlags.contains(.instantRoundVideo) {
                    flags |= (1 << 0)
                }
                attributes.append(.documentAttributeVideo(flags: flags, duration: Int32(duration), w: Int32(size.width), h: Int32(size.height)))
            case let .Audio(isVoice, duration, title, performer, waveform):
                var flags: Int32 = 0
                if isVoice {
                    flags |= Int32(1 << 10)
                }
                if let _ = title {
                    flags |= Int32(1 << 0)
                }
                if let _ = performer {
                    flags |= Int32(1 << 1)
                }
                var waveformBuffer: Buffer?
                if let waveform = waveform {
                    flags |= Int32(1 << 2)
                    waveformBuffer = Buffer(data: waveform.makeData())
                }
                attributes.append(.documentAttributeAudio(flags: flags, duration: Int32(duration), title: title, performer: performer, waveform: waveformBuffer))
        }
    }
    return attributes
}

private enum UploadedMediaTransform {
    case pending
    case done(Media?)
}

private enum UploadedMediaThumbnail {
    case pending
    case done(Api.InputFile?)
}

private func uploadedThumbnail(network: Network, postbox: Postbox, image: TelegramMediaImageRepresentation) -> Signal<Api.InputFile?, PendingMessageUploadError> {
    return multipartUpload(network: network, postbox: postbox, source: .resource(image.resource), encrypt: false, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
        |> mapError { _ -> PendingMessageUploadError in return .generic }
        |> mapToSignal { result -> Signal<Api.InputFile?, PendingMessageUploadError> in
            switch result {
                case .progress:
                    return .complete()
                case let .inputFile(inputFile):
                    return .single(inputFile)
                case .inputSecretFile:
                    return .single(nil)
            }
        }
}

public func statsCategoryForFileWithAttributes(_ attributes: [TelegramMediaFileAttribute]) -> MediaResourceStatsCategory {
    for attribute in attributes {
        switch attribute {
            case .Audio:
                return .audio
            case .Video:
                return .video
            default:
                break
        }
    }
    return .file
}

private func uploadedMediaFileContent(network: Network, postbox: Postbox, transformOutgoingMessageMedia: TransformOutgoingMessageMedia?, peerId: PeerId, messageId: MessageId?, text: String, attributes: [MessageAttribute], file: TelegramMediaFile) -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError > {
    var hintSize: Int?
    if let size = file.size {
        hintSize = size
    } else if let resource = file.resource as? LocalFileReferenceMediaResource, let size = resource.size {
        hintSize = Int(size)
    }
    let upload = multipartUpload(network: network, postbox: postbox, source: .resource(file.resource), encrypt: peerId.namespace == Namespaces.Peer.SecretChat, tag: TelegramMediaResourceFetchTag(statsCategory: statsCategoryForFileWithAttributes(file.attributes)), hintFileSize: hintSize)
        |> mapError { _ -> PendingMessageUploadError in return .generic }
    var alreadyTransformed = false
    for attribute in attributes {
        if let attribute = attribute as? OutgoingMessageInfoAttribute {
            if attribute.flags.contains(.transformedMedia) {
                alreadyTransformed = true
            }
            break
        }
    }
    
    let transform: Signal<UploadedMediaTransform, Void>
    if let transformOutgoingMessageMedia = transformOutgoingMessageMedia, let messageId = messageId, !alreadyTransformed {
        transform = .single(.pending) |> then(transformOutgoingMessageMedia(postbox, network, file, false)
            |> mapToSignal { media -> Signal<UploadedMediaTransform, NoError> in
                return postbox.modify { modifier -> UploadedMediaTransform in
                    if let media = media {
                        if let id = media.id {
                            modifier.updateMedia(id, update: media)
                            modifier.updateMessage(messageId, update: { currentMessage in
                                var storeForwardInfo: StoreMessageForwardInfo?
                                if let forwardInfo = currentMessage.forwardInfo {
                                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: nil)
                                }
                                var updatedAttributes = currentMessage.attributes
                                if let index = updatedAttributes.index(where: { $0 is OutgoingMessageInfoAttribute }){
                                    let attribute = updatedAttributes[index] as! OutgoingMessageInfoAttribute
                                    updatedAttributes[index] = attribute.withUpdatedFlags(attribute.flags.union([.transformedMedia]))
                                } else {
                                    updatedAttributes.append(OutgoingMessageInfoAttribute(uniqueId: arc4random64(), flags: [.transformedMedia]))
                                }
                                return .update(StoreMessage(id: currentMessage.id, globallyUniqueId: currentMessage.globallyUniqueId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: currentMessage.media))
                            })
                        }
                        return .done(media)
                    } else {
                        return .done(file)
                    }
                }
            })
    } else {
        transform = .single(.done(file))
    }
    
    let thumbnail: Signal<UploadedMediaThumbnail, PendingMessageUploadError> = .single(.pending) |> then(transform
        |> mapToSignalPromotingError { media -> Signal<UploadedMediaThumbnail, PendingMessageUploadError> in
            switch media {
                case .pending:
                    return .single(.pending)
                case let .done(media):
                    if let media = media as? TelegramMediaFile, let smallestThumbnail = smallestImageRepresentation(media.previewRepresentations) {
                        return uploadedThumbnail(network: network, postbox: postbox, image: smallestThumbnail)
                            |> mapError { _ -> PendingMessageUploadError in return .generic }
                            |> map { result in
                                return .done(result)
                            }
                    } else {
                        return .single(.done(nil))
                    }
            }
        })
    
    return combineLatest(upload, thumbnail)
        |> mapToSignal { content, media -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> in
            switch content {
                case let .progress(progress):
                    return .single(.progress(progress))
                case let .inputFile(inputFile):
                    if case let .done(thumbnail) = media {
                        let inputMedia: Api.InputMedia
                        var flags: Int32 = 0
                        
                        if let _ = thumbnail {
                            flags |= 1 << 2
                        }
                        
                        var ttlSeconds: Int32?
                        for attribute in attributes {
                            if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
                                flags |= 1 << 1
                                ttlSeconds = attribute.timeout
                            }
                        }
                    
                        inputMedia = Api.InputMedia.inputMediaUploadedDocument(flags: flags, file: inputFile, thumb: thumbnail, mimeType: file.mimeType, attributes: inputDocumentAttributesFromFileAttributes(file.attributes), caption: text, stickers: nil, ttlSeconds: ttlSeconds)
                        
                        return .single(.content(.media(inputMedia)))
                    } else {
                        return .complete()
                    }
                case let .inputSecretFile(file, size, key):
                    if case .done = media {
                        return .single(.content(.secretMedia(file, size, key)))
                    } else {
                        return .complete()
                    }
            }
    }
}
