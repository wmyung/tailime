import CoreFoundation
import Foundation
import TailIMECore

let portName = "com.tailime.app.cli.v1"

func printUsage() {
    print("""
    TailIME CLI (tailime-ctl)

    사용법:
      tailime-ctl status                     로컬·원격 상태 및 감지된 한영키 확인
      tailime-ctl toggle                     로컬 한영 즉시 전환
      tailime-ctl set <ko|en>                로컬 입력기를 한국어(ko) 또는 영어(en)로 절대 전환
      tailime-ctl peers                      Tailscale 피어 및 TailIME 연결 상태 조회
      tailime-ctl remote-set <ip|host> <ko|en>  페어링된 원격 Mac 입력기를 절대 전환
      tailime-ctl pair-export                내 페어링 토큰(TKP1:...) 출력
      tailime-ctl pair-import                표준입력(stdin)으로 상대 Mac 페어링 토큰 등록
      tailime-ctl pause | resume             TailIME 일시정지 / 재개
      tailime-ctl quit                       실행 중인 TailIME 종료
    """)
}

func sendIPC(_ request: [String: Any]) -> [String: Any]? {
    guard let remote = CFMessagePortCreateRemote(kCFAllocatorDefault, portName as CFString) else {
        fputs("오류: TailIME 앱이 실행 중이 아닙니다. 먼저 TailIME.app을 실행해 주세요.\n", stderr)
        return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
        remote,
        0,
        data as CFData,
        2.0,
        2.0,
        CFRunLoopMode.defaultMode.rawValue,
        &reply
    )
    guard status == kCFMessagePortSuccess, let replyData = reply?.takeRetainedValue() as Data? else {
        fputs("오류: TailIME 앱과 통신하지 못했습니다 (status \(status)).\n", stderr)
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: replyData) as? [String: Any])
}

func printJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    printUsage()
    exit(0)
}

switch cmd {
case "help", "-h", "--help":
    printUsage()
    exit(0)

case "status", "toggle", "peers", "pause", "resume", "quit", "pair-export":
    guard let resp = sendIPC(["cmd": cmd]) else { exit(1) }
    if cmd == "pair-export", let token = resp["token"] as? String {
        print(token)
        exit(0)
    }
    printJSON(resp)
    exit((resp["ok"] as? Bool) == true ? 0 : 1)

case "set":
    guard args.count >= 2 else {
        fputs("사용법: tailime-ctl set <ko|en>\n", stderr)
        exit(2)
    }
    guard let resp = sendIPC(["cmd": "set", "lang": args[1]]) else { exit(1) }
    printJSON(resp)
    exit((resp["ok"] as? Bool) == true ? 0 : 1)

case "remote-set":
    guard args.count >= 3 else {
        fputs("사용법: tailime-ctl remote-set <ip|host> <ko|en>\n", stderr)
        exit(2)
    }
    guard let resp = sendIPC(["cmd": "remote-set", "ip": args[1], "lang": args[2]]) else { exit(1) }
    printJSON(resp)
    exit((resp["ok"] as? Bool) == true ? 0 : 1)

case "pair-import":
    // Read token from stdin so pairing token never appears in process argv or shell history!
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    let token = String(data: stdinData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !token.isEmpty else {
        fputs("사용법: echo 'TKP1:...' | tailime-ctl pair-import\n", stderr)
        exit(2)
    }
    guard let resp = sendIPC(["cmd": "pair-import", "token": token]) else { exit(1) }
    printJSON(resp)
    exit((resp["ok"] as? Bool) == true ? 0 : 1)

default:
    fputs("알 수 없는 명령: \(cmd)\n", stderr)
    printUsage()
    exit(2)
}
