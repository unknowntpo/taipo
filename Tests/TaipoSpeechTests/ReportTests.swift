import Testing
@testable import TaipoSpeech

let tsv = """
s01\t這個 API 的 timeout 有點 short

s02\t今天天氣很好
s03\t明天晚上八點要跟客戶 demo

"""

func line(_ id: String, _ text: String, _ seconds: Double, _ audio: Double? = nil) -> String {
    let audioField = audio.map { ",\"audio_seconds\":\($0)" } ?? ""
    return "{\"id\":\"\(id)\",\"engine\":\"apple\",\"text\":\"\(text)\",\"seconds\":\(seconds)\(audioField)}"
}

@Test("S4: sentences.tsv and results JSONL load into ids, texts and timings")
func loading() {
    let sentences = Corpus.sentences(tsv: tsv)
    #expect(sentences.map(\.id) == ["s01", "s02", "s03"])
    #expect(sentences.first?.text == "這個 API 的 timeout 有點 short")
    let file = Corpus.results(jsonl: line("s01", "這個API的timeout有點short", 0.5, 2) + "\n" + line("s02", "今天天氣", 1))
    #expect(file.malformed == 0)
    #expect(file.records["s01"] == ResultRecord(id: "s01", engine: "apple", text: "這個API的timeout有點short", seconds: 0.5, audioSeconds: 2))
    #expect(file.records["s02"]?.audioSeconds == nil)
}

@Test("S4: sentences without a recording or a result are missing and excluded from MER")
func missing() {
    let sentences = Corpus.sentences(tsv: tsv)
    let results = Corpus.results(jsonl: [
        line("s01", "這個 API 的 timeout 有點 short", 1, 4),
        line("s02", "今天", 9, 3),
    ].joined(separator: "\n"))
    let withAll = Report.engine("apple", sentences: sentences, recorded: ["s01", "s02", "s03"], results: results)
    #expect(withAll.missing == ["s03"])
    #expect(withAll.scored.map(\.id) == ["s01", "s02"])
    #expect(withAll.mer == 4.0 / 14)

    let noRecording = Report.engine("apple", sentences: sentences, recorded: ["s01", "s03"], results: results)
    #expect(noRecording.missing == ["s02", "s03"])
    #expect(noRecording.mer == 0)
    #expect(noRecording.meanSeconds == 1)
    #expect(noRecording.rtf == 0.25)

    let none = Report.engine("apple", sentences: sentences, recorded: [], results: results)
    #expect(none.missing == ["s01", "s02", "s03"])
    #expect(none.mer == nil)
}

@Test("S4: report gives s2twp MER, mean latency, RTF and worst sentences first")
func report() {
    let sentences = Corpus.sentences(tsv: tsv)
    let results = Corpus.results(jsonl: [
        line("s01", "这个 API 的 timeout 有点 short", 1),
        line("s02", "今天天氣很好", 2),
        line("s03", "晚上", 3),
    ].joined(separator: "\n"))
    let converted = ["s01": "這個 API 的 timeout 有點 short", "s02": "今天天氣很好", "s03": "晚上"]
    let report = Report.engine("apple", sentences: sentences, recorded: ["s01", "s02", "s03"], results: results,
                               audioSeconds: ["s01": 2, "s02": 2, "s03": 2], converted: converted)
    #expect(report.mer == (3.0 + 0 + 9) / 25)
    #expect(report.merS2twp == 9.0 / 25)
    #expect(report.meanSeconds == 2)
    #expect(report.rtf == 1)
    #expect(report.worst.map(\.id) == ["s03", "s01", "s02"])
    #expect(Report.render([report]).contains("apple"))
}

@Test("S7: malformed JSONL lines are skipped and counted without stopping the report")
func malformed() {
    let jsonl = [
        line("s01", "這個 API 的 timeout 有點 short", 1),
        "not json",
        "{\"id\":\"s02\",\"engine\":\"apple\"}",
        "",
        "{\"id\":\"s03\",\"engine\":\"apple\",\"text\":\"明天晚上八點要跟客戶 demo\",\"seconds\":\"fast\"}",
        line("s03", "明天晚上八點要跟客戶 demo", 1),
    ].joined(separator: "\n")
    let file = Corpus.results(jsonl: jsonl)
    #expect(file.malformed == 3)
    #expect(file.records.keys.sorted() == ["s01", "s03"])
    let report = Report.engine("apple", sentences: Corpus.sentences(tsv: tsv), recorded: ["s01", "s02", "s03"], results: file)
    #expect(report.malformed == 3)
    #expect(report.missing == ["s02"])
    #expect(report.mer == 0)
}
