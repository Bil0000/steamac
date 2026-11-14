import AppKit

enum GuestEditCommand {
    static func keys(for selector: Selector) -> [[UInt16]]? {
        var name = NSStringFromSelector(selector)
        let selecting = name.hasSuffix("AndModifySelection:")
        if selecting { name = String(name.dropLast("AndModifySelection:".count)) + ":" }
        let keys: [UInt16]
        switch name {
        case "performFindPanelAction:": keys = [KEY.LEFTCTRL, KEY.F]
        case "copy:": keys = [KEY.LEFTCTRL, KEY.C]
        case "cut:": keys = [KEY.LEFTCTRL, KEY.X]
        case "paste:": keys = [KEY.LEFTCTRL, KEY.V]
        case "selectAll:": keys = [KEY.LEFTCTRL, KEY.A]
        case "undo:": keys = [KEY.LEFTCTRL, KEY.Z]
        case "redo:": keys = [KEY.LEFTCTRL, KEY.LEFTSHIFT, KEY.Z]
        case "moveLeft:", "moveBackward:": keys = [KEY.LEFT]
        case "moveRight:", "moveForward:": keys = [KEY.RIGHT]
        case "moveUp:": keys = [KEY.UP]
        case "moveDown:": keys = [KEY.DOWN]
        case "moveWordLeft:", "moveWordBackward:": keys = [KEY.LEFTCTRL, KEY.LEFT]
        case "moveWordRight:", "moveWordForward:": keys = [KEY.LEFTCTRL, KEY.RIGHT]
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": keys = [KEY.HOME]
        case "moveToEndOfLine:", "moveToRightEndOfLine:": keys = [KEY.END]
        case "moveToBeginningOfParagraph:": keys = [KEY.LEFTCTRL, KEY.UP]
        case "moveToEndOfParagraph:": keys = [KEY.LEFTCTRL, KEY.DOWN]
        case "moveToBeginningOfDocument:": keys = [KEY.LEFTCTRL, KEY.HOME]
        case "moveToEndOfDocument:": keys = [KEY.LEFTCTRL, KEY.END]
        case "pageUp:", "scrollPageUp:": keys = [KEY.PAGEUP]
        case "pageDown:", "scrollPageDown:": keys = [KEY.PAGEDOWN]
        case "deleteBackward:": keys = [KEY.BACKSPACE]
        case "deleteForward:": keys = [KEY.DELETE]
        case "deleteWordBackward:": keys = [KEY.LEFTCTRL, KEY.BACKSPACE]
        case "deleteWordForward:": keys = [KEY.LEFTCTRL, KEY.DELETE]
        case "deleteToBeginningOfLine:": return [[KEY.LEFTSHIFT, KEY.HOME], [KEY.BACKSPACE]]
        case "deleteToEndOfLine:": return [[KEY.LEFTSHIFT, KEY.END], [KEY.DELETE]]
        case "insertTab:": keys = [KEY.TAB]
        case "insertBacktab:": keys = [KEY.LEFTSHIFT, KEY.TAB]
        case "insertNewline:", "insertLineBreak:": keys = [KEY.ENTER]
        case "cancelOperation:": keys = [KEY.ESC]
        default: return nil
        }
        return [(selecting ? [KEY.LEFTSHIFT] : []) + keys]
    }
}

final class GuestKeyBindings: NSResponder {
    private var commands: [Selector] = []
    private var insertedText = false

    override func doCommand(by selector: Selector) { commands.append(selector) }
    override func insertText(_ insertString: Any) { insertedText = true }

    func resolve(_ event: NSEvent) -> [[UInt16]]? {
        commands.removeAll(keepingCapacity: true)
        insertedText = false
        interpretKeyEvents([event])
        guard !insertedText, !commands.isEmpty else { return nil }
        var keys: [[UInt16]] = []
        for selector in commands {
            guard let command = GuestEditCommand.keys(for: selector) else { return nil }
            keys += command
        }
        return keys
    }
}
