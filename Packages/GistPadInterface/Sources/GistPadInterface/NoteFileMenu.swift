import Foundation

struct NoteFileMenu {
    struct Year: Identifiable {
        let id: Int
        let months: [Month]
        var files: [NoteFile] { months.flatMap(\.files) }
    }

    struct Month: Identifiable {
        let id: Int
        let date: Date
        let files: [NoteFile]
    }

    private struct DatedFile {
        let file: NoteFile
        let date: Date
        let year: Int
        let month: Int
    }

    let years: [Year]
    let otherFiles: [NoteFile]

    init(files: [NoteFile]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let dated = files.compactMap { file -> DatedFile? in
            guard let date = file.date else { return nil }
            return DatedFile(
                file: file, date: date,
                year: calendar.component(.year, from: date),
                month: calendar.component(.month, from: date)
            )
        }
        years = Dictionary(grouping: dated, by: \.year)
            .sorted { $0.key > $1.key }
            .map { year, files in
                Year(
                    id: year,
                    months: Dictionary(grouping: files, by: \.month)
                        .sorted { $0.key > $1.key }
                        .map { month, files in
                            Month(
                                id: month, date: files[0].date,
                                files: files.sorted {
                                    if $0.date != $1.date { return $0.date > $1.date }
                                    return $0.file.filename < $1.file.filename
                                }.map(\.file)
                            )
                        }
                )
            }
        otherFiles = files.filter { $0.date == nil }
    }
}
