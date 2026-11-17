import Foundation
import LeonBookTodoModule
@testable import LeonBook

private struct EmailTestFailure: Error { let message: String }
private func emailExpect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw EmailTestFailure(message: message) }
}
private func emailReject(_ operation: () throws -> Void) throws {
    do { try operation() } catch is EmailError { return }
    throw EmailTestFailure(message: "Expected email validation to reject input")
}

final class EmailTests {
    func testSMTPRefusesPlaintextWithoutSendingCredentials() async throws {
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-c", #"""
        import socket
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.settimeout(15)
            print(listener.getsockname()[1], flush=True)
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(5)
                conn.sendall(b'220 localhost ESMTP test\r\n')
                stream = conn.makefile('rb')
                while True:
                    line = stream.readline()
                    if not line: break
                    command = line.split(b' ', 1)[0].strip().upper()
                    assert command not in (b'AUTH', b'MAIL', b'RCPT', b'DATA'), 'Client exposed data before TLS'
                    if command in (b'EHLO', b'HELO'):
                        conn.sendall(b'250-localhost\r\n250 AUTH PLAIN LOGIN\r\n')
                    elif command == b'QUIT':
                        conn.sendall(b'221 Bye\r\n')
                        break
                    else: conn.sendall(b'502 Unsupported\r\n')
        """#]
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        var portData = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            portData.append(byte)
        }
        guard let port = String(data: portData, encoding: .utf8), Int(port) != nil else { throw EmailTestFailure(message: "Local SMTP fixture failed to start") }
        let settings = EmailConfiguration(host: "127.0.0.1", port: port, security: .startTLS, username: "test@example.com", sender: "test@example.com")
        do {
            try await EmailSMTPTransport.send(settings: settings, password: "test-secret", recipients: ["recipient@example.com"], message: Data("private body".utf8))
            throw EmailTestFailure(message: "SMTP without STARTTLS must fail")
        } catch EmailError.delivery {}
        server.waitUntilExit()
        try emailExpect(server.terminationStatus == 0, "SMTP must fail before AUTH or message transmission")
    }

    func testValidationAndCredentialConfigEscaping() throws {
        var config = EmailConfiguration(host: " SMTP.Example.com ", username: "user@example.com", sender: "user@example.com")
        let validated = try config.validated()
        try emailExpect(validated.host == "smtp.example.com", "Host must normalize without accepting URLs")
        let recipients = try EmailConfiguration.recipients("one@example.com; two+label@example.org，one@example.com")
        try emailExpect(recipients == ["one@example.com", "two+label@example.org"], "Recipient delimiters and deduplication must work")
        for input in ["", "a@example.com,", "a@example.com\r\nBcc: other@example.com", "a b@example.com", "Name <a@example.com>"] {
            try emailReject { _ = try EmailConfiguration.recipients(input) }
        }
        config.host = "smtp.example.com/path"
        try emailReject { _ = try config.validated() }
        config.host = "smtp.example.com"; config.port = "0"
        try emailReject { _ = try config.validated() }
        config.port = "587"; config.security = .startTLS
        let command = try EmailSMTPTransport.configuration(config, password: "secret\"\\value:$()", recipients: recipients, messageFile: URL(fileURLWithPath: "/tmp/mail file.eml"))
        try emailExpect(command.contains("url = \"smtp://smtp.example.com:587\""), "STARTTLS must use smtp scheme")
        try emailExpect(command.contains("secret\\\"\\\\value:$()"), "Password characters must remain config data")
        try emailExpect(command.components(separatedBy: "mail-rcpt = ").count == 3, "Every recipient needs an SMTP envelope recipient")
        try emailReject { _ = try EmailSMTPTransport.configuration(config, password: "secret\nurl=evil", recipients: recipients, messageFile: URL(fileURLWithPath: "/tmp/mail")) }
        config.security = .tls; config.port = "465"
        let tls = try EmailSMTPTransport.configuration(config, password: "secret", recipients: recipients, messageFile: URL(fileURLWithPath: "/tmp/mail"))
        try emailExpect(tls.contains("smtps://smtp.example.com:465"), "Implicit TLS must use smtps scheme")
    }

    func testUnicodeMIMERoundTripAndSizeLimit() throws {
        let subject = String(repeating: "周报与待办 📨 ", count: 15)
        let body = "第一段 & 内容\n第二段\n.\n结束 🚀"
        let attachment = EmailAttachment(name: "会议记录与下一步计划.pdf", data: Data([0, 255, 42, 13, 10]))
        let data = try EmailMIME.message(sender: "me@example.com", recipients: ["you@example.com", "team@example.com"], subject: subject, body: body, attachments: [attachment])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("message.eml")
        try data.write(to: file)
        // An independent standards-aware parser verifies headers, MIME boundaries, and raw bytes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
        import sys
        from email import policy
        from email.parser import BytesParser
        message = BytesParser(policy=policy.default).parsebytes(open(sys.argv[1], 'rb').read())
        assert str(message['Subject']) == sys.argv[2]
        assert message.get_body(preferencelist=('plain',)).get_content() == sys.argv[3]
        files = list(message.iter_attachments())
        assert len(files) == 1 and files[0].get_filename() == sys.argv[4]
        assert files[0].get_payload(decode=True) == bytes([0, 255, 42, 13, 10])
        assert len(message['To'].addresses) == 2
        assert not message.defects
        """, file.path, subject, body, attachment.name]
        try process.run(); process.waitUntilExit()
        try emailExpect(process.terminationStatus == 0, "MIME must round-trip through a standard email parser")
        let source = String(decoding: data, as: UTF8.self)
        try emailExpect(source.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 }, "SMTP lines must remain within limits")
        try emailReject { _ = try EmailMIME.message(sender: "me@example.com", recipients: ["you@example.com"], subject: "Hello\r\nBcc: hidden@example.com", body: "", attachments: []) }
        try emailReject { _ = try EmailMIME.message(sender: "me@example.com", recipients: ["you@example.com"], subject: "Large", body: "", attachments: [.init(name: "large.bin", data: Data(count: 20 * 1024 * 1024))]) }
    }

    func testContentIncludesTasksMomentsAndAnswers() throws {
        let stamp = "2026-11-07T10:30:00Z"
        let task = TodoItem(id: "1", title: "发送计划", notes: "保留多行\n备注", priority: .high, dueDay: "2026-11-08", completedAt: stamp, createdAt: stamp, updatedAt: stamp)
        let content = EmailContent.todos([task])
        try emailExpect(content.body.contains("☑ 发送计划") && content.body.contains("2026-11-08") && content.body.contains(task.notes), "Todo mail must retain completion, due date and notes")
        try emailExpect(EmailContent.todos([]).body.isEmpty, "Empty task lists must not fabricate content")
        let remote = NativeMedia(kind: "image", name: "remote.png", size: 0, url: "https://example.com/image.png")
        let moment = NativeMoment(createdAt: stamp, id: "m1", images: [remote], tags: ["分享"], text: "正文", textRuns: [], updatedAt: stamp)
        let mail = EmailContent.moment(moment)
        try emailExpect(mail.editableBody.contains("正文") && mail.editableBody.contains("#分享") && mail.editableBody.contains(remote.url), "Moment text, tags and remote links must survive")
        try emailExpect(mail.localMedia.isEmpty, "Remote media must remain links")
        let question = NativeQuestion(id: "q", title: "问题", body: "详细描述", tags: [], createdAt: stamp, updatedAt: stamp)
        let answer = NativeQuestionAnswer(id: "a", questionID: "q", body: "**答案**", createdAt: stamp, updatedAt: stamp)
        let questionMail = EmailContent.question(question, answers: [answer])
        try emailExpect(questionMail.body.contains("详细描述") && questionMail.body.contains("答案"), "Question email must contain both question and answers")
        let article = NativeArticle(banner: nil, body: RichArticleDocument.opening + "<p>首段 &amp; 正文</p><p>第二段</p><img src=\"/media/article/photo.png\"></article>", category: "写作", excerpt: "", media: [], slug: "article", status: .published, tags: ["邮件"], title: "文章", updatedAt: stamp, publishedAt: stamp, wordCount: nil)
        let articleMail = EmailContent.article(article)
        try emailExpect(articleMail.body.contains("首段 & 正文\n第二段") && !articleMail.body.contains("<p>"), "Rich articles must become readable plain text")
        try emailExpect(articleMail.localMedia.map(\.url) == ["/media/article/photo.png"], "Inline article media must be included even without registry entries")
    }

    func testAttachmentsRejectMissingFilesAndEscapingSymlinks() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("workspace")
        let mediaDirectory = root.appendingPathComponent("media/moments")
        try manager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let store = LocalBlogStore(rootURL: root)
        let media = NativeMedia(kind: "image", name: "photo.png", size: 3, url: "/media/moments/photo.png")
        let file = mediaDirectory.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: file)
        let content = EmailContent(subject: "Photo", body: "", media: [media, media])
        let files = try await content.attachments(store: store)
        try emailExpect(files.count == 1 && files[0].data == Data([1, 2, 3]), "Attachments must preserve bytes and deduplicate URLs")
        try manager.removeItem(at: file)
        do { _ = try await content.attachments(store: store); throw EmailTestFailure(message: "Missing attachments must not silently disappear") }
        catch EmailError.missingAttachment {}
        let outside = directory.appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: outside)
        try manager.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await content.attachments(store: store); throw EmailTestFailure(message: "External symlink targets must never be attached") }
        catch EmailError.missingAttachment {}
        try emailExpect(EmailAccountStore.scope(for: root) != EmailAccountStore.scope(for: directory.appendingPathComponent("other")), "Workspace email accounts must be isolated")
    }
}
