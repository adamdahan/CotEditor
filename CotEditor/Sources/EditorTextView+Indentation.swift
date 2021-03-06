/*
 
 EditorTextView+Indentation.swift
 
 CotEditor
 https://coteditor.com
 
 Created by 1024jp on 2016-01-10.
 
 ------------------------------------------------------------------------------
 
 © 2014-2018 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 https://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

import Cocoa

extension EditorTextView {
    
    // MARK: Action Messages
    
    /// increase indent level
    @IBAction func shiftRight(_ sender: Any?) {
        
        guard self.tabWidth > 0 else { return }
        
        // get indent target
        let string = self.string as NSString
        let selectedRanges = self.selectedRanges as! [NSRange]
        
        // create indent string to prepend
        let indent = self.isAutomaticTabExpansionEnabled ? String(repeating: " ", count: self.tabWidth) : "\t"
        let indentLength = indent.utf16.count
        
        // create shifted string
        let lineRanges = string.lineRanges(for: selectedRanges)
        let newLines = lineRanges.map { indent + string.substring(with: $0) }
        
        // calculate new selection range
        let newSelectedRanges = selectedRanges.map { selectedRange -> NSRange in
            let shift = lineRanges.countPrefix { $0.location <= selectedRange.location }
            let lineCount = lineRanges.count { selectedRange.intersection($0) != nil }
            
            return NSRange(location: selectedRange.location + shift * indentLength,
                           length: selectedRange.length + (lineCount - 1) * indentLength)
        }
        
        // update textView and register action to undo manager
        self.replace(with: newLines, ranges: lineRanges, selectedRanges: newSelectedRanges,
                     actionName: NSLocalizedString("Shift Right", comment: "action name"))
    }
    
    
    /// decrease indent level
    @IBAction func shiftLeft(_ sender: Any?) {
        
        guard self.tabWidth > 0 else { return }
        
        // get range to process
        let string = self.string as NSString
        let selectedRanges = self.selectedRanges as! [NSRange]
        
        // create shifted string
        let lineRanges = string.lineRanges(for: selectedRanges)
        let lines = lineRanges.map { string.substring(with: $0) }
        let dropCounts = lines.map { line -> Int in
            guard let firstCharacter = line.first else { return 0 }
            
            switch firstCharacter {
            case "\t": return 1
            case " ": return min(line.countPrefix(while: { $0 == " " }), self.tabWidth)
            default: return 0
            }
        }
        
        // cancel if not shifted
        guard dropCounts.contains(where: { $0 > 0 }) else { return }
        
        // create shifted string
        let newLines = zip(lines, dropCounts).map { String($0.dropFirst($1)) }
        
        // calculate new selection range
        let droppedRanges: [NSRange] = zip(lineRanges, dropCounts)
            .filter { $1 > 0 }
            .map { NSRange(location: $0.location, length: $1) }
        let newSelectedRanges = selectedRanges.map { selectedRange -> NSRange in
            let locationDiff = droppedRanges
                .prefix { $0.location < selectedRange.location }
                .reduce(0) { $0 + (selectedRange.intersection($1) ?? $1).length }
            let lengthDiff = droppedRanges
                .flatMap { selectedRange.intersection($0) }
                .reduce(0) { $0 + $1.length }
            
            return NSRange(location: selectedRange.location - locationDiff,
                           length: selectedRange.length - lengthDiff )
        }
        
        // update textView and register action to undo manager
        self.replace(with: newLines, ranges: lineRanges, selectedRanges: newSelectedRanges,
                     actionName: NSLocalizedString("Shift Left", comment: "action name"))
    }
    
    
    /// shift selection from segmented control button
    @IBAction func shift(_ sender: NSSegmentedControl) {
        
        switch sender.selectedSegment {
        case 0:
            self.shiftLeft(sender)
        case 1:
            self.shiftRight(sender)
        default:
            assertionFailure("Segmented shift button must have only 2 segments.")
        }
    }
    
    
    /// standardize inentation in selection to spaces
    @IBAction func convertIndentationToSpaces(_ sender: Any?) {
        
        self.convertIndentation(style: .space)
    }
    
    
    /// standardize inentation in selection to tabs
    @IBAction func convertIndentationToTabs(_ sender: Any?) {
        
        self.convertIndentation(style: .tab)
    }
    
    
    
    // MARK: Private Methods
    
    /// standardize inentation of given ranges
    private func convertIndentation(style: IndentStyle) {
        
        guard !self.string.isEmpty else { return }
        
        let ranges: [NSRange] = {
            if self.selectedRange.length == 0 {  // convert all if nothing selected
                return [self.string.nsRange]
            }
            return self.selectedRanges as! [NSRange]
        }()
        
        var replacementRanges = [NSRange]()
        var replacementStrings = [String]()
        
        for range in ranges {
            let selectedString = (self.string as NSString).substring(with: range)
            let convertedString = selectedString.standardizingIndent(to: style, tabWidth: self.tabWidth)
            
            guard convertedString != selectedString else { continue }  // no need to convert
            
            replacementRanges.append(range)
            replacementStrings.append(convertedString)
        }
        
        self.replace(with: replacementStrings, ranges: replacementRanges, selectedRanges: nil,
                     actionName: NSLocalizedString("Convert Indentation", comment: "action name"))
    }
    
}
