//
//  StateController.swift
//  HomeInspection
//  
//  Singleton used to manage the state of an inspection
//
//  Created by Jared Speck on 1/11/17.
//  Copyright © 2017 Jared Speck. All rights reserved.
//

import UIKit

class StateController {
    
    /**
     * State Variable
     *
     * Holds the State controller singleton, managing the current state of a single inspection.
     */
    static let state = StateController();
    private let INSPECTION = 1
    private let DEFAULT_DATA = 2
    private let RESULT = 3
    private let TOKEN = 4
    
    
    
    /* Properties */
    
    
    
    // TODO: Need a way to get the next available inspection id from the server. Maybe use a temp id for offline cache, then assign a permanent id right before integrating into database.
    private var inspectionId: Int? = nil
    private var nextResultId: Int = 0
    private var token: String? = nil
    
    // Arrays are indexed by their respective unique id's
    
    // List of inspection results with unique resultId
    private(set) var results = [Result?]()
    
    // List of all section names with unique sectionId
    private(set) var sections = [Section]()
    
    // List of all subsection names with unique subSectionId
    private(set) var subsections = [SubSection]()
    
    // List of all comments with unique commentId
    private(set) var comments = [Comment]()
    
    // Mapping for section num, subsection num, and comment num in a subsection to a single commentId. NEED TO FIX MAPPING FUNCTION THAT FILLS THESE IN CORRECTLY
    //private var commentIds = [[[Int]]]()
    
    private var wasPullError: Bool = false
    private var dataIsInitialized: Bool = false
    private var reusableResultIds = [Int]()
    
    /* End of Properties */
    
    
    // Default initializer - Hidden to prevent reinitializing state. If one needs to load new values, use the loadState function (not implemented yet).
    private init() {
        print("init state")
        
        self.dataIsInitialized = false
        postFromURL(option: TOKEN, httpBody: createTokenJSON())
        
        // Add a null (id = 0) comment (its function TBD later, maybe errors?)
        comments.append(Comment(commentId: 0, subSectionId: -1, rank: -1, commentText: "ERROR, COMMENT WITH ID 0", defaultFlags: [Int8](), active: false))
        
        // Get and parse data from database
        getFromURL(option: DEFAULT_DATA)
        
        
        // Polling for completion of database pull and parsing. Simple, but semaphores may be more efficient design (save extra fraction of a second and no wake then sleep again)
        while (!wasPullError && !self.dataIsInitialized) {
            sleep(1)
        }
        
        // Sort arrays so DB id matches index
        sections = sections.sorted(by: {$0.sectionId < $1.sectionId})
        subsections = subsections.sorted(by: {$0.subSectionId < $1.subSectionId})
        comments = comments.sorted(by: {$0.commentId < $1.commentId})
        
    }
    
    
    /**
     * Function Implementations for transmitting data to/from UI
     *
     * Takes in the result id and the item to change, updates the results,
     * then returns the value stored in the results for testing/updating the
     * calling controller's view
     */
    // Appends the results array with a new entry with the given comment id. Returns the result id of the new entry
    func userAddedResult(commentId: Int) -> Int {
        var returnId: Int
        
        if (reusableResultIds.count > 0) {
            // Place result in one of the holes in the list
            returnId = reusableResultIds.popLast()!
            results[returnId] = Result(id: returnId, inspectionId: getNextInspId(), commentId: commentId, variantId: nil)
        }
        else {
            // Add result to the end of the list
            results.append(Result(id: nextResultId, inspectionId: getNextInspId(), commentId: commentId, variantId: nil))
            returnId = nextResultId
            nextResultId += 1
        }
        
        comments[commentId].resultId = returnId
        
        return returnId
        
    }
    func userRemovedResult(resultId: Int) -> Void {
        
        let removedResult = results[resultId]
        let removedCommentId = removedResult!.commentId
        
        comments[removedCommentId!].resultId = nil
        
        // Add index of hole to reuasable id list
        reusableResultIds.append((Int(resultId)))
        
        // Make a hole in the results list
        results[resultId] = nil
    }
    
    // Adds one to the severity and modulo's the result by 3. Returns the new severity value
    func userChangedSeverity(resultId: Int) -> Int {
        self.results[Int(resultId)]!.severity = (self.results[Int(resultId)]!.severity % 2) + 1
        return self.results[resultId]!.severity
    }
    
    func userChangedNote(resultId: Int, note: String) -> String {
        return note
    }
    
    func userChangedPhoto(resultId: Int, photoPath: String) -> String {
        return photoPath
    }
    
    func userChangedFlags(resultId: Int, flagNums: [Int8]) -> [Int8] {
        return flagNums
    }
    

    
    
    // Get subsection cell information
    
    func getSubSectionText(sectionIndex: Int, subSectionNum: Int) -> String {
        let section = self.sections[sectionIndex]
        let subSectionId = section.subSectionIds[subSectionNum]
        
        for index in 0..<subsections.count {
            if (subsections[index].subSectionId == subSectionId) {
                return subsections[index].subSectionName!
            }
        }
        
        return "Not Found"
    }
    
    
    // Get comment cell information
    
    // Translates the cells location into a comment id
    func getCommentId(sectionNum: Int, subSectionNum: Int, rowNum: Int) -> Int? {
        print("Getting comment ID for cell in Section: \(sectionNum), Subsection \(subSectionNum), with Rank: \(rowNum)")
        let currentSection = sections[sectionNum]
        let currentSubSection = subsections[currentSection.subSectionIds[subSectionNum]]
        
        let commentIndex = rowNum - currentSubSection.variantIds.count
        let commentId = currentSubSection.commentIds[commentIndex]
        
        print("\(commentId)/\(comments.count)")
    
        return commentId
    }
    
    func getCommentText(commentId: Int) -> String {
        //print("Accessing comment \(commentId)/\(comments.count)")
        if (commentId >= comments.count) {
            return "Error getting text for comment: Id \(commentId) out of range (\(comments.count))"
        }
        return comments[commentId].commentText
    }
    
    func getSection(subSectionId: Int) -> Int {
        print("getting section for subsection \(subSectionId)")
        
        return subsections[subSectionId].sectionId
    }
    
    // End of UI data transfer functions
    
    
    
    
    // Other Functions
    
    /**
     * Checks local cache if offline, or makes query to online database to find the next
     * unused inspection id.
     * Returns a negative id if offline, storing the inspection locally. This id is
     * overwritten once the report is uploaded to the database
     * Returns a positive id if successfully assigned a permanent id in the database
     */
    
    func getNextInspId() -> Int {
        // TODO: Implement later, for now always assigns the first slot in the local inspection cache
        return -1;
    }
    
    
    
    /* Database Integration Functions */
    func createFlagString(flags: [Int]) -> String {
        var flagString: String = ""
        for flag in flags {
            flagString += String(flag)
        }
        return flagString
    }
    
    func createTokenJSON() -> JSON {
        var body: JSON = [:]
        body["username"].string = "Test"
        body["password"].string = "badpassword1"
        return body
    }
    
    func createResultJSON(result: Result) -> JSON{
        var body: JSON = [:]
        body["id"].intValue = result.id
        body["insp_id"].intValue = result.inspectionId
        body["com_id"].intValue = result.commentId!
        body["variant_id"].intValue = result.variantId!
        body["add_on"].string = result.note
        body["severity"].intValue = result.severity
        //body["flags"].string = ...
        //body["photoPath"].string = result.photoPath
        return body
    }
    
    func postFromURL(option: Int, httpBody: JSON) {
        var endPointURL: String = ""
        
        switch option {
        case self.TOKEN:
            endPointURL = "http://crm.professionalhomeinspection.net/api/users/token.json"
            break
        case self.RESULT:
            endPointURL = "http://crm.professionalhomeinspection.net/api/results/add" + self.token!
            break
        default:
            break
        }
        
        guard let url = URL(string: endPointURL) else {
            print("Error cannot create POST URL")
            self.wasPullError = true
            return
        }
        do {
            var urlRequest = URLRequest(url: url)
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.addValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.httpMethod = "POST"
            try urlRequest.httpBody = httpBody.rawData()
            
            let session = URLSession.shared
            let task = session.dataTask(with: urlRequest) {
                (data, response, error) in
                guard error == nil else {
                    print("error calling POST on option")
                    self.wasPullError = true
                    return
                }
                guard let responseData = data else {
                    print ("Error: did not recieve data")
                    self.wasPullError = true
                    return
                }
                do {
                    let json = JSON(data: responseData)
                    switch option {
                    case self.TOKEN:
                        self.parseToken(json: json)
                        break
                    case self.RESULT:
                        self.parseResult(json: json)
                        break
                    default:
                        print("Cannot parse JSON of type \(option)")
                        break
                    }
                }
            }
            task.resume()
        }
        catch {
            print("Caught exception in POST URL")
        }
    }
    func parseResult(json: JSON) {
        if !json["success"].boolValue {
            print("Error with something")
        }
        else {
            for (_, resultJson) in json["data"] {
                //Do things with the data
            }
        }
    }
    func parseToken(json: JSON) {
        if !json["success"].boolValue {
            print("Error recieving token")
            self.wasPullError = true
            return
        }
        self.token = "?token=" + json["data"]["token"].string!
        print("Got token ")
        print(self.token ?? "Error didn't get token")
    }
    
    
    func getFromURL(option: Int) {
        var endPointURL: String = ""
        
        switch option {
        case self.INSPECTION:
            break
        case self.DEFAULT_DATA:
            endPointURL = "http://crm.professionalhomeinspection.net/api/sections.json" + self.token!
            break
        case self.RESULT:
            endPointURL = "http://crm.professionalhomeinspection.net/api/results.json" + self.token!
            break
        default:
            break
        }
        
        guard let url = URL(string: endPointURL) else {
            print("Error: cannot create GET URL")
            self.wasPullError = true
            return
        }
        let urlRequest = URLRequest(url: url)
        
        let session = URLSession.shared
        
        let task = session.dataTask(with: urlRequest) {
            (data, response, error) in
            guard error == nil else {
                print("error calling GET on option")
                print(error!)
                self.wasPullError = true
                return
            }
            guard let responseData = data else {
                print ("Error: did not recieve data")
                self.wasPullError = true
                return
            }
            do {
                let json = JSON(data: responseData)
                switch option {
                case self.INSPECTION:
                    // Parse inspection?
                    break
                case self.DEFAULT_DATA:
                    self.parseDefaultData(json: json)
                    self.dataIsInitialized = true
                    break;
                case self.RESULT:
                    //Write this function soon
                    // Parse results?
                    break
                default:
                    print("Cannot parse JSON of type \(option)")
                    break
                }
            }
        }
        task.resume()
    }
    
    func parseDefaultData(json: JSON) {
        if !json["success"].boolValue {
            print("Error")
        }
        else {
            for (_, sectionJson) in json["data"] {
                self.sections.append(
                    Section(
                        id: sectionJson["id"].intValue,
                        name: sectionJson["name"].string
                    )
                )
                
                for (_, subSectionJson) in sectionJson["subsections"] {
                    self.subsections.append(
                        SubSection(
                            subSectionId: subSectionJson["id"].intValue,
                            name: subSectionJson["name"].string,
                            sectionId: subSectionJson["sec_id"].intValue
                        )
                    )
                    
                    // Add subsec id to section's subsec list
                    self.sections.last!.subSectionIds.append(subsections.last!.subSectionId)
                    
                    for (_, commentJson) in subSectionJson["comments"] {
                        self.comments.append(
                            Comment(
                                commentId: commentJson["id"].intValue,
                                subSectionId: commentJson["subsec_id"].intValue,
                                rank: commentJson["rank"].intValue,
                                commentText: commentJson["comment"].string,
                                defaultFlags: [], //Fix this
                                active: commentJson["active"] == 1 ? true:false
                            )
                        )
                        
                        // Add comment id to subsection's comment list
                        self.subsections.last!.commentIds.append(comments.last!.commentId)
                    }
                }
            }
        }
    }
    
    
    /* End of Database Integration Functions */
    
}
