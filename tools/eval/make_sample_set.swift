// Synthetic test set for `--eval` (the plan §5 step 4). Standalone, never part of the app target.
// Writes <outdir>/<Destination>/<files> plus <outdir>/_none (files that belong nowhere), and
// <outdir>-three: the same files as Flowers/Resumes/Receipts with everything else in _none.
// Deterministic: same names, text and pixels every run (pdf/docx metadata timestamps may differ).
// Run: swiftc -O tools/eval/make_sample_set.swift -o "$TMPDIR/make_sample_set" && "$TMPDIR/make_sample_set" "$TMPDIR/evalset"

import AppKit
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    print("usage: make_sample_set <outdir>")
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: out)

func folder(_ name: String) -> URL {
    let url = out.appendingPathComponent(name, isDirectory: true)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: writers

func renderText(_ text: String, width: Int = 1200, height: Int = 1600, fontSize: CGFloat = 36) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(in: CGRect(x: 70, y: 70, width: width - 140, height: height - 140),
                            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                             .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// a pdf with real text, one or two pages
func writeTextPDF(_ text: String, _ url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(in: box.insetBy(dx: 60, dy: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
}

// a pdf page that is only a picture of text, like a scan
func writeImagePDF(_ image: CGImage, _ url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 816)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
}

func writeDocx(_ text: String, _ url: URL) {
    let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    let data = try! string.data(from: NSRange(location: 0, length: string.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    try! data.write(to: url)
}

func writeText(_ text: String, _ url: URL) {
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func copyPhotos(from source: String, to destination: URL) -> Int {
    let dir = URL(fileURLWithPath: source)
    let names = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".heic") }.sorted() ?? []
    for name in names {
        // these are relative symlinks into /System; copy what they point at
        let data = try! Data(contentsOf: dir.appendingPathComponent(name).resolvingSymlinksInPath())
        try! data.write(to: destination.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_")))
    }
    return names.count
}

// MARK: fixed vocab, indexed by file number

let people = ["Priya Shah", "Marcus Chen", "Jordan Lee", "Sofia Alvarez", "Daniel Okafor", "Emma Novak", "Liam Patel", "Ava Kim"]
let schools = ["University of Waterloo", "McGill University", "University of Toronto", "UBC", "Queen's University", "Western University", "McMaster University", "University of Ottawa"]
let companies = ["Shopify", "Wealthsimple", "RBC", "Lightspeed", "Ubisoft", "Telus", "Clio", "Benevity"]
let roles = ["software engineering intern", "data analyst co-op", "product design intern", "backend developer", "research assistant", "QA engineer", "mobile developer", "machine learning intern"]
let skillSets = ["Swift, Python, SQL, Git", "Java, Kotlin, REST APIs, Docker", "Figma, user research, prototyping", "Go, PostgreSQL, Kubernetes", "R, statistics, data visualization", "Selenium, test plans, CI", "React Native, TypeScript, Firebase", "PyTorch, NumPy, experiment tracking"]
let stores = ["TRADER JOE'S", "LOBLAWS", "SHOPPERS DRUG MART", "BEST BUY", "INDIGO BOOKS", "TIM HORTONS", "IKEA", "CANADIAN TIRE"]
let itemSets = [["BANANAS 0.99", "OAT MILK 3.49", "COFFEE BEANS 8.99"], ["BREAD 2.79", "EGGS DOZEN 4.29", "CHEDDAR 6.49"],
                ["SHAMPOO 7.99", "TOOTHPASTE 3.29", "VITAMIN D 11.49"], ["USB-C CABLE 19.99", "MOUSE 34.99", "HDMI ADAPTER 24.99"],
                ["NOTEBOOK 12.95", "PENS 6.50", "NOVEL 22.99"], ["COFFEE 2.15", "BAGEL 2.49", "TIMBITS 4.99"],
                ["LAMP 39.99", "STORAGE BOX 14.99", "PLANT POT 9.99"], ["MOTOR OIL 32.99", "WIPERS 24.99", "FUSES 5.49"]]
let courses = [("CS 135", "functional programming"), ("MATH 239", "combinatorics"), ("STAT 230", "probability"),
               ("CS 246", "object-oriented design"), ("PHYS 121", "mechanics"), ("ECON 101", "microeconomics"),
               ("CS 136", "algorithm design"), ("MATH 137", "calculus")]
let topics = ["recursion and structural induction", "graph colouring and planarity", "discrete random variables",
              "design patterns and inheritance", "Newton's laws and free body diagrams", "supply and demand elasticity",
              "memory models and pointers", "limits, continuity and derivatives"]

// MARK: resumes (8)

func resumeText(_ i: Int) -> String {
    let person = people[i % people.count]
    let email = person.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
    let openings = ["Objective: a full-time role where I can ship reliable software.",
                    "Summary: curious builder who enjoys turning messy data into clear decisions.",
                    "Profile: detail-oriented student looking for an internship in a fast team.",
                    "About me: I like small teams, honest feedback and hard problems."]
    return """
    \(person)
    \(email) · (416) 555-01\(10 + i) · linkedin.com/in/\(person.lowercased().replacingOccurrences(of: " ", with: ""))

    \(openings[i % openings.count])

    Education
    Bachelor of \(i % 2 == 0 ? "Computer Science" : "Applied Mathematics"), \(schools[i % schools.count]), expected 202\(5 + i % 3). GPA 3.\(6 + i % 4).
    Relevant coursework: data structures, algorithms, databases, operating systems.

    Experience
    \(roles[i % roles.count].capitalized), \(companies[i % companies.count]), summer 202\(3 + i % 2)
    - Built and maintained features used by thousands of customers; wrote tests and reviewed code.
    - Worked with designers and product managers; presented results to the team every sprint.
    \(roles[(i + 3) % roles.count].capitalized), \(companies[(i + 2) % companies.count]), 202\(2 + i % 2)
    - Improved a reporting pipeline and cut processing time; documented the work for the next intern.

    Skills
    \(skillSets[i % skillSets.count]); communication; teamwork.

    References available on request.
    """
}

let resumes = folder("Resumes")
writeTextPDF(resumeText(0), resumes.appendingPathComponent("doc_final2.pdf"))
writeTextPDF(resumeText(1), resumes.appendingPathComponent("Priya_Shah_CV.pdf"))
writeTextPDF(resumeText(2), resumes.appendingPathComponent("resume_2025.pdf"))
writeDocx(resumeText(3), resumes.appendingPathComponent("cv_draft.docx"))
writeDocx(resumeText(4), resumes.appendingPathComponent("Marcus_Chen.docx"))
writeTextPDF(resumeText(5), resumes.appendingPathComponent("application_materials.pdf"))
writeDocx(resumeText(6), resumes.appendingPathComponent("JLee_2024.docx"))
writeTextPDF(resumeText(7), resumes.appendingPathComponent("portfolio_summary.pdf"))

// MARK: receipts (8)

func receiptText(_ i: Int) -> String {
    let items = itemSets[i % itemSets.count]
    let amounts = items.map { Double($0.split(separator: " ").last!)! }
    let subtotal = amounts.reduce(0, +)
    let tax = (subtotal * 0.13 * 100).rounded() / 100
    let cards = ["VISA ****1234", "MASTERCARD ****5521", "AMEX ****3009", "DEBIT ****7781"]
    return """
    \(stores[i % stores.count]) #\(500 + i * 17)
    \(120 + i * 3) MAIN ST, TORONTO ON
    2026-0\(1 + i % 9)-1\(i % 9) 1\(i % 10):2\(i % 6)

    \(items.joined(separator: "\n"))

    SUBTOTAL      \(String(format: "%.2f", subtotal))
    HST 13%       \(String(format: "%.2f", tax))
    TOTAL        $\(String(format: "%.2f", subtotal + tax))

    \(cards[i % cards.count])
    CASHIER \(["MIA", "RAJ", "TOM", "LEA"][i % 4]) · ORDER \(118204 + i)
    THANK YOU FOR SHOPPING
    """
}

func invoiceText(_ i: Int) -> String {
    let items = itemSets[(i + 3) % itemSets.count]
    return """
    INVOICE #00\(42 + i)
    \(companies[i % companies.count]) Inc. · billing@example.com
    Invoice date: 2026-0\(2 + i % 7)-0\(1 + i % 9)   Due date: 2026-0\(3 + i % 6)-15
    Bill to: \(people[i % people.count])

    Item                         Qty    Amount
    \(items.map { "\($0)     1" }.joined(separator: "\n"))

    Subtotal, tax (HST 13%) and the total amount due are shown below.
    Payment received with thanks. Order number \(118204 + i). Keep this receipt for your records.
    Total paid: $\(String(format: "%.2f", Double(30 + i * 7) + 0.45))
    """
}

let receipts = folder("Receipts")
writePNG(renderText(receiptText(0)), receipts.appendingPathComponent("scan_0912.png"))
writePNG(renderText(receiptText(1)), receipts.appendingPathComponent("IMG_4471.png"))
writePNG(renderText(receiptText(2), width: 900, height: 1400, fontSize: 30), receipts.appendingPathComponent("photo_2026_store.png"))
writeTextPDF(invoiceText(3), receipts.appendingPathComponent("order_118204.pdf"))
writeTextPDF(invoiceText(4), receipts.appendingPathComponent("Invoice-0042.pdf"))
writeImagePDF(renderText(receiptText(5)), receipts.appendingPathComponent("Scanned_Document.pdf"))
writeImagePDF(renderText(receiptText(6)), receipts.appendingPathComponent("doc20260312.pdf"))
writeTextPDF(invoiceText(7), receipts.appendingPathComponent("payment_confirmation.pdf"))

// MARK: school (8)

func lectureText(_ i: Int) -> String {
    let (code, subject) = courses[i % courses.count]
    return """
    \(code): \(subject.capitalized). Lecture \(7 + i) notes.
    Today: \(topics[i % topics.count]).
    Professor \(people[(i + 4) % people.count].split(separator: " ").last!) reviewed last week's material, then worked three examples on the board.
    Key definitions and a theorem with proof sketch; the exam will ask you to apply it, not memorize it.
    Practice: chapter \(3 + i % 5) problems 1-12. Office hours Thursday. The midterm covers lectures 1-\(6 + i).
    Reminder: the next assignment is due Friday at 11:59 pm on the course site. Quiz in lab next week.
    """
}

func homeworkText(_ i: Int) -> String {
    let (code, subject) = courses[(i + 2) % courses.count]
    return """
    \(code) Assignment \(1 + i % 6): \(subject).
    Due: Friday, 11:59 pm. Submit your solution as a single PDF. Show all work; partial marks are given.
    Problem 1. Prove the statement about \(topics[(i + 1) % topics.count]) by induction.
    Problem 2. Implement the function described in lecture and state its running time.
    Problem 3. Give a counterexample to the claim, or explain why none exists.
    Academic integrity: you may discuss ideas with classmates, but write your own solution.
    """
}

let school = folder("School")
writeTextPDF(lectureText(0), school.appendingPathComponent("lecture07_recursion.pdf"))
writeDocx(homeworkText(1), school.appendingPathComponent("hw3.docx"))
writeText("""
    \(courses[2].0) Syllabus, Fall 2026. Instructor: Professor \(people[3]). Lectures Monday and Wednesday.
    Course topics: \(topics[2]), \(topics[5]), estimation and testing. Textbook chapters 1-9.
    Grading: weekly homework 20%, quizzes 10%, midterm exam 30%, final exam 40%.
    Late assignments lose 10% per day. Office hours Tuesday 2-4 pm. Labs start in week two.
    Missed exams need a verification of illness form. Check the course site for announcements.
    """, school.appendingPathComponent("syllabus.txt"))
writeTextPDF(lectureText(3), school.appendingPathComponent("midterm_review.pdf"))
writeDocx(homeworkText(4), school.appendingPathComponent("lab4_report.docx"))
writeText(lectureText(5), school.appendingPathComponent("notes_week5.txt"))
writeTextPDF(homeworkText(6), school.appendingPathComponent("problem_set_2.pdf"))
writeDocx(lectureText(7), school.appendingPathComponent("CS136_review.docx"))

// MARK: photos

let flowerCount = copyPhotos(from: "/Library/User Pictures/Flowers", to: folder("Flowers"))
let animalCount = copyPhotos(from: "/Library/User Pictures/Animals", to: folder("Animals"))
let sportsCount = copyPhotos(from: "/Library/User Pictures/Sports", to: folder("Sports"))

// MARK: _none, files that belong nowhere

let none = folder("_none")
try! Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: none.appendingPathComponent("song.mp3"))
try! Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: none.appendingPathComponent("installer.dmg"))
writeText("""
    Ideas for the weekend: hike the trail by the lake, try the new ramen place downtown, return the library DVD,
    call grandma on Sunday afternoon, water the balcony herbs, look up bike repair shops near the station,
    and finally sort the cables drawer. Maybe a movie night with friends if the weather turns.
    """, none.appendingPathComponent("notes_misc.txt"))
var csv = "id,value,weight\n"
for row in 0..<40 {
    csv += "\(row),\((row * 37) % 101),\((row * 13) % 17)\n"
}
writeText(csv, none.appendingPathComponent("random.csv"))
let zipSource = out.appendingPathComponent("zip-src", isDirectory: true)
try! fm.createDirectory(at: zipSource, withIntermediateDirectories: true)
writeText("old config backup\n", zipSource.appendingPathComponent("settings.conf"))
let ditto = Process()
ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
ditto.arguments = ["-c", "-k", "--norsrc", zipSource.path, none.appendingPathComponent("backup.zip").path]
try! ditto.run()
ditto.waitUntilExit()
try? fm.removeItem(at: zipSource)

print("wrote \(out.path): Flowers \(flowerCount), Animals \(animalCount), Sports \(sportsCount), Resumes 8, Receipts 8, School 8, _none 5")

// MARK: <outdir>-three, the step 5 layout: only Flowers, Resumes and Receipts are destinations, and the
// other photos and the school papers belong nowhere. one learned photo or pdf must not make these confident

let three = URL(fileURLWithPath: out.path + "-three", isDirectory: true)
try? fm.removeItem(at: three)
let threeNone = three.appendingPathComponent("_none", isDirectory: true)
try! fm.createDirectory(at: threeNone, withIntermediateDirectories: true)
for name in ["Flowers", "Resumes", "Receipts"] {
    try! fm.copyItem(at: out.appendingPathComponent(name), to: three.appendingPathComponent(name))
}
var controls = 0
for name in ["Animals", "Sports", "School", "_none"] {
    let source = out.appendingPathComponent(name, isDirectory: true)
    for file in try! fm.contentsOfDirectory(atPath: source.path).sorted() where !file.hasPrefix(".") {
        try! fm.copyItem(at: source.appendingPathComponent(file), to: threeNone.appendingPathComponent(file))
        controls += 1
    }
}
print("wrote \(three.path): Flowers \(flowerCount), Resumes 8, Receipts 8, _none \(controls) (animals, sports, school, junk)")
