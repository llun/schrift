// Captured from the installed BlockNote 0.56.0 + yjs 13.6.33 in node/jsdom with
// the Docs schema (the phase 0 S3 harness's node_modules, `schema.mjs`): each seed
// is the client-1 update BlockNote's `replaceBlocks` wrote, and each XML is the
// `document-store` fragment after `editor.moveBlocksUp(block)` or
// `editor.moveBlocksDown(block)` ran on a client-2 replica (PR06d).
enum BlockNoteMoveCaptures {
    struct Capture {
        let name: String
        let block: String
        let up: Bool
        let seed: String
        let xml: String
    }

    static let captures: [Capture] = [
        Capture(
            name: "up-sibling", block: "b", up: true,
            seed:
                "ARkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYSgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcBYYcBAQMOYmxvY2tDb250YWluZXIHAAEJAwlwYXJhZ3JhcGgHAAEKBgQAAQsBYigAAQoPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQoJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQoNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEJAmlkAXcBYocBCQMOYmxvY2tDb250YWluZXIHAAERAwlwYXJhZ3JhcGgHAAESBgQAARMBYygAARIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARIJdGV4dENvbG9yAXcHZGVmYXVsdCgAARINdGV4dEFsaWdubWVudAF3BGxlZnQoAAERAmlkAXcBYwA=",
            xml:
                #"<blockgroup><blockcontainer id="b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b</paragraph></blockcontainer><blockcontainer id="a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a</paragraph></blockcontainer><blockcontainer id="c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">c</paragraph></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "down-into-children", block: "a", up: false,
            seed:
                "ASIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYSgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcBYYcBAQMOYmxvY2tDb250YWluZXIHAAEJAwlwYXJhZ3JhcGgHAAEKBgQAAQsBYigAAQoPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQoJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQoNdGV4dEFsaWdubWVudAF3BGxlZnSHAQoDCmJsb2NrR3JvdXAHAAEQAw5ibG9ja0NvbnRhaW5lcgcAAREDCXBhcmFncmFwaAcAARIGBAABEwJiMSgAARIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARIJdGV4dENvbG9yAXcHZGVmYXVsdCgAARINdGV4dEFsaWdubWVudAF3BGxlZnQoAAERAmlkAXcCYjEoAAEJAmlkAXcBYocBCQMOYmxvY2tDb250YWluZXIHAAEbAwlwYXJhZ3JhcGgHAAEcBgQAAR0BYygAARwPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARwJdGV4dENvbG9yAXcHZGVmYXVsdCgAARwNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEbAmlkAXcBYwA=",
            xml:
                #"<blockgroup><blockcontainer id="b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b</paragraph><blockgroup><blockcontainer id="a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a</paragraph></blockcontainer><blockcontainer id="b1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b1</paragraph></blockcontainer></blockgroup></blockcontainer><blockcontainer id="c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">c</paragraph></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "up-into-children", block: "b", up: true,
            seed:
                "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYSgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAEIAw5ibG9ja0NvbnRhaW5lcgcAAQkDCXBhcmFncmFwaAcAAQoGBAABCwJhMSgAAQoPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQoJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQoNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEJAmlkAXcCYTEoAAEBAmlkAXcBYYcBAQMOYmxvY2tDb250YWluZXIHAAETAwlwYXJhZ3JhcGgHAAEUBgQAARUBYigAARQPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARQJdGV4dENvbG9yAXcHZGVmYXVsdCgAARQNdGV4dEFsaWdubWVudAF3BGxlZnQoAAETAmlkAXcBYgA=",
            xml:
                #"<blockgroup><blockcontainer id="a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a</paragraph><blockgroup><blockcontainer id="a1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a1</paragraph></blockcontainer><blockcontainer id="b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "up-out-of-parent", block: "x", up: true,
            seed:
                "ASMBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBcCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAEIAw5ibG9ja0NvbnRhaW5lcgcAAQkDCXBhcmFncmFwaAcAAQoGBAABCwF4KAABCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABCg10ZXh0QWxpZ25tZW50AXcEbGVmdIcBCgMKYmxvY2tHcm91cAcAARADDmJsb2NrQ29udGFpbmVyBwABEQMJcGFyYWdyYXBoBwABEgYEAAETAngxKAABEg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABEgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABEg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAARECaWQBdwJ4MSgAAQkCaWQBdwF4hwEJAw5ibG9ja0NvbnRhaW5lcgcAARsDCXBhcmFncmFwaAcAARwGBAABHQF5KAABHA9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABHAl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABHA10ZXh0QWxpZ25tZW50AXcEbGVmdCgAARsCaWQBdwF5KAABAQJpZAF3AXAA",
            xml:
                #"<blockgroup><blockcontainer id="x"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x</paragraph><blockgroup><blockcontainer id="x1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x1</paragraph></blockcontainer></blockgroup></blockcontainer><blockcontainer id="p"><paragraph backgroundColor="default" textAlignment="left" textColor="default">p</paragraph><blockgroup><blockcontainer id="y"><paragraph backgroundColor="default" textAlignment="left" textColor="default">y</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "down-sole-child", block: "only", up: false,
            seed:
                "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBcCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAEIAw5ibG9ja0NvbnRhaW5lcgcAAQkDCXBhcmFncmFwaAcAAQoGBAABCwRvbmx5KAABCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABCg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQkCaWQBdwRvbmx5KAABAQJpZAF3AXCHAQEDDmJsb2NrQ29udGFpbmVyBwABFQMJcGFyYWdyYXBoBwABFgYEAAEXAXQoAAEWD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEWCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEWDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABFQJpZAF3AXQA",
            xml:
                #"<blockgroup><blockcontainer id="p"><paragraph backgroundColor="default" textAlignment="left" textColor="default">p</paragraph></blockcontainer><blockcontainer id="only"><paragraph backgroundColor="default" textAlignment="left" textColor="default">only</paragraph></blockcontainer><blockcontainer id="t"><paragraph backgroundColor="default" textAlignment="left" textColor="default">t</paragraph></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "down-toggle", block: "t", up: false,
            seed:
                "ASIBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw50b2dnbGVMaXN0SXRlbQcAAQIGBAABAwVUaXRsZSgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnSHAQIDCmJsb2NrR3JvdXAHAAEMAw5ibG9ja0NvbnRhaW5lcgcAAQ0DCXBhcmFncmFwaAcAAQ4GBAABDwJjMSgAAQ4PYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQ4JdGV4dENvbG9yAXcHZGVmYXVsdCgAAQ4NdGV4dEFsaWdubWVudAF3BGxlZnQoAAENAmlkAXcCYzGHAQ0DDmJsb2NrQ29udGFpbmVyBwABFgMJcGFyYWdyYXBoBwABFwYEAAEYAmMyKAABFw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABFwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABFw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAARYCaWQBdwJjMigAAQECaWQBdwF0hwEBAw5ibG9ja0NvbnRhaW5lcgcAASADCXBhcmFncmFwaAcAASEGBAABIgF4KAABIQ9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABIQl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABIQ10ZXh0QWxpZ25tZW50AXcEbGVmdCgAASACaWQBdwF4AA==",
            xml:
                #"<blockgroup><blockcontainer id="x"><paragraph backgroundColor="default" textAlignment="left" textColor="default">x</paragraph></blockcontainer><blockcontainer id="t"><togglelistitem backgroundColor="default" textAlignment="left" textColor="default">Title</togglelistitem><blockgroup><blockcontainer id="c1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">c1</paragraph></blockcontainer><blockcontainer id="c2"><paragraph backgroundColor="default" textAlignment="left" textColor="default">c2</paragraph></blockcontainer></blockgroup></blockcontainer></blockgroup>"#
        ),
        Capture(
            name: "up-marks-props", block: "b", up: true,
            seed:
                "AR8BAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMBYSgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcBYYcBAQMOYmxvY2tDb250YWluZXIHAAEJAwdoZWFkaW5nBwABCgYGAAELBGJvbGQCe32EAQwEQm9sZIYBEARib2xkBG51bGyEAREGIHBsYWluKAABCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABCgl0ZXh0Q29sb3IBdwNyZWQoAAEKDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABCgVsZXZlbAF9AigAAQoMaXNUb2dnbGVhYmxlAXmHAQoDCmJsb2NrR3JvdXAHAAEdAw5ibG9ja0NvbnRhaW5lcgcAAR4DCXBhcmFncmFwaAcAAR8GBAABIAJiMSgAAR8PYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAR8JdGV4dENvbG9yAXcHZGVmYXVsdCgAAR8NdGV4dEFsaWdubWVudAF3BGxlZnQoAAEeAmlkAXcCYjEoAAEJAmlkAXcBYgA=",
            xml:
                #"<blockgroup><blockcontainer id="b"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="red"><bold>Bold</bold> plain</heading><blockgroup><blockcontainer id="b1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">b1</paragraph></blockcontainer></blockgroup></blockcontainer><blockcontainer id="a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">a</paragraph></blockcontainer></blockgroup>"#
        ),
    ]
}
