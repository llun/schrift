// Captured from real BlockNote 0.56.0 + yjs 13.6.33 in node/jsdom with the Docs
// schema (the phase 0 S3 harness): each seed is the client-1 update BlockNote's
// `replaceBlocks` wrote, and each case's XML is the `document-store` fragment
// after BlockNote's own command ran on a client-2 replica of that seed — Enter
// and Backspace through its keyboard shortcuts, type changes through
// `editor.updateBlock`. Two entries are not BlockNote's output: `split-code`
// keeps the seed (BlockNote's Enter inserts a "\n" line break there, so the
// writer refuses the split), and `split-surrogate` is checked against the
// writer's code-point snap instead (BlockNote writes U+FFFD into both halves).
// `enter-empty-nested` records BlockNote's outdent of an empty nested block on
// Enter, a keyboard-level choice the writer leaves to its caller.
enum BlockNoteWriterCaptures {
    // Real BlockNote 0.56 + yjs 13.6.33: codeBlock has marks: "".
    // toggleStyles on a range is a no-op; insertContent with explicit marks
    // and insertText with stored marks both insert plain text. Conversion back
    // to a paragraph retains no marks. Captured in .review/scratch/capture-findings.mjs.
    static let codeBlockFormat: [(label: String, updateBase64: String, xml: String)] = [
        (
            "seed",
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwljb2RlQmxvY2sHAAECBgQAAQMDYWJjKAABAghsYW5ndWFnZQF3BHRleHQoAAEBAmlkAXcBYwA=",
            #"<blockgroup><blockcontainer id="c"><codeblock language="text">abc</codeblock></blockcontainer></blockgroup>"#
        ),
        (
            "code-format",
            "AAA=",
            #"<blockgroup><blockcontainer id="c"><codeblock language="text">abc</codeblock></blockcontainer></blockgroup>"#
        ),
        (
            "convert to paragraph",
            "AQYCAEcBAgMJcGFyYWdyYXBoBwACAAYEAAIBA2FiYygAAgAPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAgAJdGV4dENvbG9yAXcHZGVmYXVsdCgAAgANdGV4dEFsaWdubWVudAF3BGxlZnQBAQECBg==",
            #"<blockgroup><blockcontainer id="c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">abc</paragraph></blockcontainer></blockgroup>"#
        ),
    ]

    static let codeBlockTyping: [(label: String, updateBase64: String, xml: String)] = [
        (
            "seed",
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwljb2RlQmxvY2sHAAECBgQAAQMCYWMoAAECCGxhbmd1YWdlAXcEdGV4dCgAAQECaWQBdwFjAA==",
            #"<blockgroup><blockcontainer id="c"><codeblock language="text">ac</codeblock></blockcontainer></blockgroup>"#
        ),
        (
            "code-typing-explicit",
            "AQECAMQBBAEFAWIA",
            #"<blockgroup><blockcontainer id="c"><codeblock language="text">abc</codeblock></blockcontainer></blockgroup>"#
        ),
        (
            "convert to paragraph",
            "AQYCAUcBAgMJcGFyYWdyYXBoBwACAQYEAAICA2FiYygAAgEPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAgEJdGV4dENvbG9yAXcHZGVmYXVsdCgAAgENdGV4dEFsaWdubWVudAF3BGxlZnQCAgEAAQEBAgU=",
            #"<blockgroup><blockcontainer id="c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">abc</paragraph></blockcontainer></blockgroup>"#
        ),
    ]

    static let seeds: [String: String] = [
        "p-mixed-to-code":
            "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMHQmVmb3JlIIcBAwMRdXNlck1lbnRpb25JbmxpbmUoAAELBnVzZXJJZAF3BnVzZXItMSgAAQsIZnVsbE5hbWUBdwxBZGEgTG92ZWxhY2WHAQsGBAABDgggbWlkZGxlIIcBDgMWaW50ZXJsaW5raW5nTGlua0lubGluZSgAARcFZG9jSWQBdwVkb2MtMSgAARcHYmxvY2tJZAF3CHRhcmdldC0xKAABFwhkaXNhYmxlZAF5KAABFwd0cmlnZ2VyAXcBL4cBFwYEAAEcBiBtYXRoIIcBHAMEbWF0aAcAASMGBAABJAN4XjKHASMGBAABKAYgYWZ0ZXIoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3A3AtZwA=",
        "p-marked-to-code":
            "AREBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgYAAQMEYm9sZAJ7fYQBBARib2xkhgEIBGJvbGQEbnVsbIYBCQRsaW5rH3siaHJlZiI6Imh0dHBzOi8vZXhhbXBsZS5jb20vIn2EAQoEbGlua4YBDgRsaW5rBG51bGyGAQ8JdGV4dENvbG9yFXsic3RyaW5nVmFsdWUiOiJyZWQifYQBEAQgcmVkhgEUCXRleHRDb2xvcgRudWxsKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQECaWQBdwNwLW0A",
        "code-to-p":
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwljb2RlQmxvY2sHAAECBgQAAQMJbGV0IHggPSAxKAABAghsYW5ndWFnZQF3BHRleHQoAAEBAmlkAXcDYy0xAA==",
        "p-empty-to-code":
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3A3AtegA=",
        "join-into-nested":
            "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGcGFyZW50KAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBAgMKYmxvY2tHcm91cAcAAQ0DDmJsb2NrQ29udGFpbmVyBwABDgMJcGFyYWdyYXBoBwABDwYEAAEQBWNoaWxkKAABDw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABDwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABDw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQ4CaWQBdwVjaGlsZCgAAQECaWQBdwZwYXJlbnSHAQEDDmJsb2NrQ29udGFpbmVyBwABGwMJcGFyYWdyYXBoBwABHAYEAAEdBnNlY29uZCgAARwPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARwJdGV4dENvbG9yAXcHZGVmYXVsdCgAARwNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEbAmlkAXcGc2Vjb25kAA==",
        "join-into-deep":
            "ASMBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGcGFyZW50KAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBAgMKYmxvY2tHcm91cAcAAQ0DDmJsb2NrQ29udGFpbmVyBwABDgMJcGFyYWdyYXBoBwABDwYEAAEQBWNoaWxkKAABDw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABDwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABDw10ZXh0QWxpZ25tZW50AXcEbGVmdIcBDwMKYmxvY2tHcm91cAcAARkDDmJsb2NrQ29udGFpbmVyBwABGgMJcGFyYWdyYXBoBwABGwYEAAEcBWdyYW5kKAABGw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABGwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABGw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAARoCaWQBdwVncmFuZCgAAQ4CaWQBdwVjaGlsZCgAAQECaWQBdwZwYXJlbnSHAQEDDmJsb2NrQ29udGFpbmVyBwABKAMJcGFyYWdyYXBoBwABKQYEAAEqBnNlY29uZCgAASkPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAASkJdGV4dENvbG9yAXcHZGVmYXVsdCgAASkNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEoAmlkAXcGc2Vjb25kAA==",
        "join-nested-source":
            "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMFZmlyc3QoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3BWZpcnN0hwEBAw5ibG9ja0NvbnRhaW5lcgcAAQ0DCXBhcmFncmFwaAcAAQ4GBAABDwZzZWNvbmQoAAEOD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEOCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEODXRleHRBbGlnbm1lbnQBdwRsZWZ0hwEOAwpibG9ja0dyb3VwBwABGQMOYmxvY2tDb250YWluZXIHAAEaAwlwYXJhZ3JhcGgHAAEbBgQAARwDa2lkKAABGw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABGwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABGw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAARoCaWQBdwNraWQoAAENAmlkAXcGc2Vjb25kAA==",
        "split-nested":
            "ARIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMKSGVsbG9Xb3JsZCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAERAw5ibG9ja0NvbnRhaW5lcgcAARIDCXBhcmFncmFwaAcAARMGBAABFANraWQoAAETD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAETCXRleHRDb2xvcgF3B2RlZmF1bHQoAAETDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABEgJpZAF3A2tpZCgAAQECaWQBdwNwLW4A",
        "split-styled":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMKSGVsbG9Xb3JsZCgAAQIPYmFja2dyb3VuZENvbG9yAXcDcmVkKAABAgl0ZXh0Q29sb3IBdwRibHVlKAABAg10ZXh0QWxpZ25tZW50AXcGY2VudGVyKAABAQJpZAF3A3AtcwA=",
        "split-heading":
            "AQsBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwdoZWFkaW5nBwABAgYEAAEDCkhlbGxvV29ybGQoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAgVsZXZlbAF9AigAAQIMaXNUb2dnbGVhYmxlAXkoAAEBAmlkAXcDaC0xAA==",
        "styled-to-heading":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGU3R5bGVkKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwNyZWQoAAECCXRleHRDb2xvcgF3BGJsdWUoAAECDXRleHRBbGlnbm1lbnQBdwZjZW50ZXIoAAEBAmlkAXcDcC1wAA==",
        "heading-to-numbered":
            "AQsBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwdoZWFkaW5nBwABAgYEAAEDBEhlYWQoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwVyaWdodCgAAQIFbGV2ZWwBfQMoAAECDGlzVG9nZ2xlYWJsZQF5KAABAQJpZAF3A2gtMgA=",
        "nested-to-heading":
            "ARIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGUGFyZW50KAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBAgMKYmxvY2tHcm91cAcAAQ0DDmJsb2NrQ29udGFpbmVyBwABDgMJcGFyYWdyYXBoBwABDwYEAAEQA2tpZCgAAQ8PYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQ8JdGV4dENvbG9yAXcHZGVmYXVsdCgAAQ8NdGV4dEFsaWdubWVudAF3BGxlZnQoAAEOAmlkAXcDa2lkKAABAQJpZAF3A3AtawA=",
        "join-into-empty":
            "AQ8BAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3BWVtcHR5hwEBAw5ibG9ja0NvbnRhaW5lcgcAAQcDCXBhcmFncmFwaAcAAQgGBAABCQVXb3JsZCgAAQgPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQgJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQgNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEHAmlkAXcEZnVsbAA=",
        "join-into-empty-heading":
            "AREBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwdoZWFkaW5nKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQIFbGV2ZWwBfQEoAAECDGlzVG9nZ2xlYWJsZQF5KAABAQJpZAF3B2VtcHR5LWiHAQEDDmJsb2NrQ29udGFpbmVyBwABCQMJcGFyYWdyYXBoBwABCgYEAAELBVdvcmxkKAABCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABCg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQkCaWQBdwRmdWxsAA==",
        "split-surrogate":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGYfCfmIBiKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQECaWQBdwNwLXUA",
        "split-bullet-styled":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw5idWxsZXRMaXN0SXRlbQcAAQIGBAABAwpIZWxsb1dvcmxkKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwNyZWQoAAECCXRleHRDb2xvcgF3BGJsdWUoAAECDXRleHRBbGlnbm1lbnQBdwZjZW50ZXIoAAEBAmlkAXcDYi0xAA==",
        "split-check":
            "AQoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw1jaGVja0xpc3RJdGVtBwABAgYEAAEDCkhlbGxvV29ybGQoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAgdjaGVja2VkAXgoAAEBAmlkAXcDay0xAA==",
        "split-numbered":
            "AQoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAxBudW1iZXJlZExpc3RJdGVtBwABAgYEAAEDCkhlbGxvV29ybGQoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAgVzdGFydAF9AygAAQECaWQBdwNuLTEA",
        "split-at-start":
            "ARIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMFSGVsbG8oAAECD2JhY2tncm91bmRDb2xvcgF3A3JlZCgAAQIJdGV4dENvbG9yAXcEYmx1ZSgAAQINdGV4dEFsaWdubWVudAF3BmNlbnRlcocBAgMKYmxvY2tHcm91cAcAAQwDDmJsb2NrQ29udGFpbmVyBwABDQMJcGFyYWdyYXBoBwABDgYEAAEPA2tpZCgAAQ4PYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQ4JdGV4dENvbG9yAXcHZGVmYXVsdCgAAQ4NdGV4dEFsaWdubWVudAF3BGxlZnQoAAENAmlkAXcDa2lkKAABAQJpZAF3A3AtdAA=",
        "split-check-at-start":
            "AQoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw1jaGVja0xpc3RJdGVtBwABAgYEAAEDBUhlbGxvKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQIHY2hlY2tlZAF4KAABAQJpZAF3A2stMgA=",
        "split-empty":
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3BHAtZTAA",
        "split-code":
            "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwljb2RlQmxvY2sHAAECBgQAAQMCYWIoAAECCGxhbmd1YWdlAXcEdGV4dCgAAQECaWQBdwNjLTIA",
        "join-nested-both":
            "ASMBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGcGFyZW50KAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBAgMKYmxvY2tHcm91cAcAAQ0DDmJsb2NrQ29udGFpbmVyBwABDgMJcGFyYWdyYXBoBwABDwYEAAEQBWNoaWxkKAABDw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABDwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABDw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQ4CaWQBdwVjaGlsZCgAAQECaWQBdwZwYXJlbnSHAQEDDmJsb2NrQ29udGFpbmVyBwABGwMJcGFyYWdyYXBoBwABHAYEAAEdBnNlY29uZCgAARwPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARwJdGV4dENvbG9yAXcHZGVmYXVsdCgAARwNdGV4dEFsaWdubWVudAF3BGxlZnSHARwDCmJsb2NrR3JvdXAHAAEnAw5ibG9ja0NvbnRhaW5lcgcAASgDCXBhcmFncmFwaAcAASkGBAABKgNraWQoAAEpD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEpCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEpDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABKAJpZAF3A2tpZCgAARsCaWQBdwZzZWNvbmQA",
        "join-into-empty-nested":
            "ASEBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMGcGFyZW50KAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBAgMKYmxvY2tHcm91cAcAAQ0DDmJsb2NrQ29udGFpbmVyBwABDgMJcGFyYWdyYXBoKAABDw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABDwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABDw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQ4CaWQBdwVjaGlsZCgAAQECaWQBdwZwYXJlbnSHAQEDDmJsb2NrQ29udGFpbmVyBwABFQMJcGFyYWdyYXBoBwABFgYEAAEXBnNlY29uZCgAARYPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARYJdGV4dENvbG9yAXcHZGVmYXVsdCgAARYNdGV4dEFsaWdubWVudAF3BGxlZnSHARYDCmJsb2NrR3JvdXAHAAEhAw5ibG9ja0NvbnRhaW5lcgcAASIDCXBhcmFncmFwaAcAASMGBAABJANraWQoAAEjD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEjCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEjDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABIgJpZAF3A2tpZCgAARUCaWQBdwZzZWNvbmQA",
        "join-into-empty-styled":
            "AQ8BAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3A3JlZCgAAQIJdGV4dENvbG9yAXcEYmx1ZSgAAQINdGV4dEFsaWdubWVudAF3BmNlbnRlcigAAQECaWQBdwVlbXB0eYcBAQMOYmxvY2tDb250YWluZXIHAAEHAwlwYXJhZ3JhcGgHAAEIBgQAAQkFV29ybGQoAAEID2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEICXRleHRDb2xvcgF3B2RlZmF1bHQoAAEIDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABBwJpZAF3BGZ1bGwA",
        "join-into-empty-with-kids":
            "ARgBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3BWVtcHR5hwEBAw5ibG9ja0NvbnRhaW5lcgcAAQcDCXBhcmFncmFwaAcAAQgGBAABCQVXb3JsZCgAAQgPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQgJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQgNdGV4dEFsaWdubWVudAF3BGxlZnSHAQgDCmJsb2NrR3JvdXAHAAESAw5ibG9ja0NvbnRhaW5lcgcAARMDCXBhcmFncmFwaAcAARQGBAABFQNraWQoAAEUD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEUCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEUDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABEwJpZAF3A2tpZCgAAQcCaWQBdwRmdWxsAA==",
        "join-into-code":
            "AQ8BAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwljb2RlQmxvY2sHAAECBgQAAQMCYWIoAAECCGxhbmd1YWdlAXcEdGV4dCgAAQECaWQBdwNjLTOHAQEDDmJsb2NrQ29udGFpbmVyBwABCAMJcGFyYWdyYXBoBwABCQYEAAEKAmNkKAABCQ9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCQl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABCQ10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQgCaWQBdwVhZnRlcgA=",
        "join-mixed":
            "ASIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcFZmlyc3SHAQEDDmJsb2NrQ29udGFpbmVyBwABCQMJcGFyYWdyYXBoBwABCgYEAAELB0JlZm9yZSCHAQsDEXVzZXJNZW50aW9uSW5saW5lKAABEwZ1c2VySWQBdwZ1c2VyLTEoAAETCGZ1bGxOYW1lAXcMQWRhIExvdmVsYWNlhwETBgQAARYIIG1pZGRsZSCHARYDFmludGVybGlua2luZ0xpbmtJbmxpbmUoAAEfBWRvY0lkAXcFZG9jLTEoAAEfB2Jsb2NrSWQBdwh0YXJnZXQtMSgAAR8IZGlzYWJsZWQBeSgAAR8HdHJpZ2dlcgF3AS+HAR8GBAABJAYgbWF0aCCHASQDBG1hdGgHAAErBgQAASwDeF4yhwErBgQAATAGIGFmdGVyKAABCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABCg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQkCaWQBdwNwLWcA",
        "check-toggle":
            "AQoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw1jaGVja0xpc3RJdGVtBwABAgYEAAEDBFRhc2soAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAgdjaGVja2VkAXkoAAEBAmlkAXcDay0zAA==",
        "heading-level":
            "AQsBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwdoZWFkaW5nBwABAgYEAAEDBEhlYWQoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAgVsZXZlbAF9ASgAAQIMaXNUb2dnbGVhYmxlAXkoAAEBAmlkAXcDaC0zAA==",
        "p-same-type":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcDcC1xAA==",
        "p-same-type-color":
            "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcDcmVkKAABAgl0ZXh0Q29sb3IBdwRibHVlKAABAg10ZXh0QWxpZ25tZW50AXcGY2VudGVyKAABAQJpZAF3A3AtcQA=",
        "hb-type":
            "AQwBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYYcBAwMJaGFyZEJyZWFrhwEFBgQAAQYBYigAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcCaGIA",
        "hb-join-into":
            "ARQBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYYcBAwMJaGFyZEJyZWFrhwEFBgQAAQYBYigAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcFZmlyc3SHAQEDDmJsb2NrQ29udGFpbmVyBwABDAMJcGFyYWdyYXBoBwABDQYEAAEOAWMoAAEND2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAENCXRleHRDb2xvcgF3B2RlZmF1bHQoAAENDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABDAJpZAF3BnNlY29uZAA=",
        "hb-join-source":
            "ARQBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcFZmlyc3SHAQEDDmJsb2NrQ29udGFpbmVyBwABCQMJcGFyYWdyYXBoBwABCgYEAAELAWGHAQsDCWhhcmRCcmVha4cBDQYEAAEOAWIoAAEKD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEKCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEKDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABCQJpZAF3BnNlY29uZAA=",
        "enter-empty-nested":
            "ARABAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAEIAw5ibG9ja0NvbnRhaW5lcgcAAQkDCXBhcmFncmFwaCgAAQoPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQoJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQoNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEJAmlkAXcDa2lkKAABAQJpZAF3BnBhcmVudAA=",
        "divider-seed":
            "ARQBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBeCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcBYYcBAQMOYmxvY2tDb250YWluZXIHAAEJAwdkaXZpZGVyKAABCQJpZAF3AWSHAQkDDmJsb2NrQ29udGFpbmVyBwABDAMJcGFyYWdyYXBoBwABDQYEAAEOAXkoAAEND2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAENCXRleHRDb2xvcgF3B2RlZmF1bHQoAAENDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABDAJpZAF3AWIA",
    ]

    static let captures: [String: (seed: String, xml: String)] = [
        "p-mixed-to-code": (
            "p-mixed-to-code",
            #"<blockgroup><blockcontainer id="p-g"><codeblock language="text">Before  middle  math x^2 after</codeblock></blockcontainer></blockgroup>"#
        ),
        "p-marked-to-code": (
            "p-marked-to-code",
            #"<blockgroup><blockcontainer id="p-m"><codeblock language="text">boldlink red</codeblock></blockcontainer></blockgroup>"#
        ),
        "code-to-p": (
            "code-to-p",
            #"<blockgroup><blockcontainer id="c-1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">let x = 1</paragraph></blockcontainer></blockgroup>"#
        ),
        "p-mixed-to-heading": (
            "p-mixed-to-code",
            #"<blockgroup><blockcontainer id="p-g"><heading backgroundColor="default" isToggleable="false" level="3" textAlignment="left" textColor="default">Before <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> middle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</heading></blockcontainer></blockgroup>"#
        ),
        "p-mixed-to-check": (
            "p-mixed-to-code",
            #"<blockgroup><blockcontainer id="p-g"><checklistitem backgroundColor="default" checked="true" textAlignment="left" textColor="default">Before <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> middle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</checklistitem></blockcontainer></blockgroup>"#
        ),
        "p-empty-to-code": (
            "p-empty-to-code",
            #"<blockgroup><blockcontainer id="p-z"><codeblock language="text"></codeblock></blockcontainer></blockgroup>"#
        ),
        "join-into-nested": (
            "join-into-nested",
            #"<blockgroup><blockcontainer id="parent"><paragraph backgroundColor="default" textAlignment="left" textColor="default">parent</paragraph><blockgroup><blockcontainer id="child"><paragraph backgroundColor="default" textAlignment="left" textColor="default">childsecond</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "join-into-deep": (
            "join-into-deep",
            #"<blockgroup><blockcontainer id="parent"><paragraph backgroundColor="default" textAlignment="left" textColor="default">parent</paragraph><blockgroup><blockcontainer id="child"><paragraph backgroundColor="default" textAlignment="left" textColor="default">child</paragraph><blockgroup><blockcontainer id="grand"><paragraph backgroundColor="default" textAlignment="left" textColor="default">grandsecond</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "join-nested-source": (
            "join-nested-source",
            #"<blockgroup><blockcontainer id="first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">firstsecond</paragraph></blockcontainer><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup>"#
        ),
        "split-nested": (
            "split-nested",
            #"<blockgroup><blockcontainer id="p-n"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hello</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "split-nested-end": (
            "split-nested",
            #"<blockgroup><blockcontainer id="p-n"><paragraph backgroundColor="default" textAlignment="left" textColor="default">HelloWorld</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "split-styled": (
            "split-styled",
            #"<blockgroup><blockcontainer id="p-s"><paragraph backgroundColor="red" textAlignment="center" textColor="blue">Hello</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph></blockcontainer></blockgroup>"#
        ),
        "split-heading": (
            "split-heading",
            #"<blockgroup><blockcontainer id="h-1"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">Hello</heading></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph></blockcontainer></blockgroup>"#
        ),
        "styled-to-heading": (
            "styled-to-heading",
            #"<blockgroup><blockcontainer id="p-p"><heading backgroundColor="red" isToggleable="false" level="2" textAlignment="center" textColor="blue">Styled</heading></blockcontainer></blockgroup>"#
        ),
        "styled-to-code": (
            "styled-to-heading",
            #"<blockgroup><blockcontainer id="p-p"><codeblock language="text">Styled</codeblock></blockcontainer></blockgroup>"#
        ),
        "heading-to-numbered": (
            "heading-to-numbered",
            #"<blockgroup><blockcontainer id="h-2"><numberedlistitem backgroundColor="default" start="undefined" textAlignment="right" textColor="default">Head</numberedlistitem></blockcontainer></blockgroup>"#
        ),
        "nested-to-heading": (
            "nested-to-heading",
            #"<blockgroup><blockcontainer id="p-k"><heading backgroundColor="default" isToggleable="false" level="1" textAlignment="left" textColor="default">Parent</heading><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "join-into-empty": (
            "join-into-empty",
            #"<blockgroup><blockcontainer id="full"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph></blockcontainer></blockgroup>"#
        ),
        "join-into-empty-heading": (
            "join-into-empty-heading",
            #"<blockgroup><blockcontainer id="empty-h"><heading backgroundColor="default" isToggleable="false" level="1" textAlignment="left" textColor="default">World</heading></blockcontainer></blockgroup>"#
        ),
        "split-surrogate": (
            "split-surrogate",
            #"<blockgroup><blockcontainer id="p-u"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a�</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">�b</paragraph></blockcontainer></blockgroup>"#
        ),
        "split-bullet-styled": (
            "split-bullet-styled",
            #"<blockgroup><blockcontainer id="b-1"><bulletlistitem backgroundColor="red" textAlignment="center" textColor="blue">Hello</bulletlistitem></blockcontainer><blockcontainer id="1"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">World</bulletlistitem></blockcontainer></blockgroup>"#
        ),
        "split-check": (
            "split-check",
            #"<blockgroup><blockcontainer id="k-1"><checklistitem backgroundColor="default" checked="true" textAlignment="left" textColor="default">Hello</checklistitem></blockcontainer><blockcontainer id="1"><checklistitem backgroundColor="default" checked="false" textAlignment="left" textColor="default">World</checklistitem></blockcontainer></blockgroup>"#
        ),
        "split-numbered": (
            "split-numbered",
            #"<blockgroup><blockcontainer id="n-1"><numberedlistitem backgroundColor="default" start="3" textAlignment="left" textColor="default">Hello</numberedlistitem></blockcontainer><blockcontainer id="1"><numberedlistitem backgroundColor="default" start="undefined" textAlignment="left" textColor="default">World</numberedlistitem></blockcontainer></blockgroup>"#
        ),
        "split-at-start": (
            "split-at-start",
            #"<blockgroup><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="p-t"><paragraph backgroundColor="red" textAlignment="center" textColor="blue">Hello</paragraph><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "split-check-at-start": (
            "split-check-at-start",
            #"<blockgroup><blockcontainer id="1"><checklistitem backgroundColor="default" checked="false" textAlignment="left" textColor="default"></checklistitem></blockcontainer><blockcontainer id="k-2"><checklistitem backgroundColor="default" checked="true" textAlignment="left" textColor="default">Hello</checklistitem></blockcontainer></blockgroup>"#
        ),
        "split-empty": (
            "split-empty",
            #"<blockgroup><blockcontainer id="p-e0"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
        ),
        "split-code": (
            "split-code",
            #"<blockgroup><blockcontainer id="c-2"><codeblock language="text">ab</codeblock></blockcontainer></blockgroup>"#
        ),
        "split-mixed": (
            "p-mixed-to-code",
            #"<blockgroup><blockcontainer id="p-g"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Before <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> </paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">middle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</paragraph></blockcontainer></blockgroup>"#
        ),
        "join-nested-both": (
            "join-nested-both",
            #"<blockgroup><blockcontainer id="parent"><paragraph backgroundColor="default" textAlignment="left" textColor="default">parent</paragraph><blockgroup><blockcontainer id="child"><paragraph backgroundColor="default" textAlignment="left" textColor="default">childsecond</paragraph></blockcontainer></blockgroup></blockcontainer><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup>"#
        ),
        "join-into-empty-nested": (
            "join-into-empty-nested",
            #"<blockgroup><blockcontainer id="parent"><paragraph backgroundColor="default" textAlignment="left" textColor="default">parent</paragraph><blockgroup><blockcontainer id="second"><paragraph backgroundColor="default" textAlignment="left" textColor="default">second</paragraph><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "join-into-empty-styled": (
            "join-into-empty-styled",
            #"<blockgroup><blockcontainer id="empty"><paragraph backgroundColor="red" textAlignment="center" textColor="blue">World</paragraph></blockcontainer></blockgroup>"#
        ),
        "join-into-empty-with-kids": (
            "join-into-empty-with-kids",
            #"<blockgroup><blockcontainer id="full"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph><blockgroup><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default">kid</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        "join-into-code": (
            "join-into-code",
            #"<blockgroup><blockcontainer id="c-3"><codeblock language="text">ab</codeblock></blockcontainer><blockcontainer id="after"><paragraph backgroundColor="default" textAlignment="left" textColor="default">cd</paragraph></blockcontainer></blockgroup>"#
        ),
        "join-mixed": (
            "join-mixed",
            #"<blockgroup><blockcontainer id="first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">xBefore <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> middle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</paragraph></blockcontainer></blockgroup>"#
        ),
        "check-toggle": (
            "check-toggle",
            #"<blockgroup><blockcontainer id="k-3"><checklistitem backgroundColor="default" checked="true" textAlignment="left" textColor="default">Task</checklistitem></blockcontainer></blockgroup>"#
        ),
        "check-toggle-typed": (
            "check-toggle",
            #"<blockgroup><blockcontainer id="k-3"><checklistitem backgroundColor="default" checked="true" textAlignment="left" textColor="default">Task</checklistitem></blockcontainer></blockgroup>"#
        ),
        "heading-level": (
            "heading-level",
            #"<blockgroup><blockcontainer id="h-3"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">Head</heading></blockcontainer></blockgroup>"#
        ),
        "heading-level-props-only": (
            "heading-level",
            #"<blockgroup><blockcontainer id="h-3"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">Head</heading></blockcontainer></blockgroup>"#
        ),
        "p-same-type": (
            "p-same-type",
            #"<blockgroup><blockcontainer id="p-q"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x</paragraph></blockcontainer></blockgroup>"#
        ),
        "p-same-type-color": (
            "p-same-type-color",
            #"<blockgroup><blockcontainer id="p-q"><paragraph backgroundColor="red" textAlignment="center" textColor="green">x</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-type": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a<hardbreak></hardbreak>Zb</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-split-after": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a<hardbreak></hardbreak></paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-split-before": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default"><hardbreak></hardbreak>b</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-join-into": (
            "hb-join-into",
            #"<blockgroup><blockcontainer id="first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a<hardbreak></hardbreak>bc</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-join-source": (
            "hb-join-source",
            #"<blockgroup><blockcontainer id="first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">xa<hardbreak></hardbreak>b</paragraph></blockcontainer></blockgroup>"#
        ),
        "hb-to-code": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><codeblock language="text">ab</codeblock></blockcontainer></blockgroup>"#
        ),
        "hb-to-heading": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">a<hardbreak></hardbreak>b</heading></blockcontainer></blockgroup>"#
        ),
        "hb-delete": (
            "hb-type",
            #"<blockgroup><blockcontainer id="hb"><paragraph backgroundColor="default" textAlignment="left" textColor="default">ab</paragraph></blockcontainer></blockgroup>"#
        ),
        "enter-empty-nested": (
            "enter-empty-nested",
            #"<blockgroup><blockcontainer id="parent"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x</paragraph></blockcontainer><blockcontainer id="kid"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
        ),
        "divider-seed": (
            "divider-seed",
            #"<blockgroup><blockcontainer id="a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x</paragraph></blockcontainer><blockcontainer id="d"><divider></divider></blockcontainer><blockcontainer id="b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">y</paragraph></blockcontainer></blockgroup>"#
        ),
    ]
}
