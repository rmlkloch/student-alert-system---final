import ballerina/http;
import ballerina/time;
import ballerina/log;

// Configuration constants
const int MAX_QUESTIONS_PER_WINDOW = 3;
const decimal TIME_WINDOW_MINUTES = 10.0;
const decimal COOLDOWN_MINUTES = 5.0;

// Data structures
type Student record {
    string id;
    string name;
    string email;
    QuestionHistory[] questionHistory;
    boolean isBlocked;
    int totalQuestions;
    decimal? blockedUntil;
};

type QuestionHistory record {
    decimal timestamp;
    string question;
};

type QuestionRequest record {
    string studentId;
    string studentName;
    string studentEmail;
    string question;
};

type AlertResponse record {
    boolean allowed;
    string message;
    int remainingQuestions?;
    decimal? cooldownUntil?;
    string alertLevel?;
};

// In-memory storage (in production, use a database)
map<Student> students = {};

// Create HTTP listener
listener http:Listener httpListener = new(8080);

// Add a root service for basic info
@http:ServiceConfig {
    cors: {
        allowOrigins: ["*"],
        allowCredentials: false,
        allowHeaders: ["CORELATION_ID", "Content-Type", "Authorization"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        maxAge: 84900
    }
}
service / on httpListener {
    resource function get .() returns string {
        return "Student Alert System API is running! Visit /api/health for health check.";
    }
    
    resource function get api() returns string {
        return "API endpoints available at /api/";
    }

    // Handle favicon.ico requests
    resource function get favicon\.ico() returns http:NotFound {
        return http:NOT_FOUND;
    }
}

// Main service with CORS
@http:ServiceConfig {
    cors: {
        allowOrigins: ["*"],
        allowCredentials: false,
        allowHeaders: ["CORELATION_ID", "Content-Type", "Authorization"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        maxAge: 84900
    }
}
service /api on httpListener {

    // Handle preflight OPTIONS requests
    resource function options .(http:Request req) returns http:Response {
        http:Response res = new;
        res.setHeader("Access-Control-Allow-Origin", "*");
        res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
        res.setHeader("Access-Control-Max-Age", "86400");
        res.statusCode = 200;
        return res;
    }

    // Submit a question
    resource function post questions(QuestionRequest request) returns AlertResponse|error {
        decimal currentTime = <decimal>time:utcNow()[0];
        
        // Get or create student record
        Student student = students[request.studentId] ?: {
            id: request.studentId,
            name: request.studentName,
            email: request.studentEmail,
            questionHistory: [],
            isBlocked: false,
            totalQuestions: 0,
            blockedUntil: ()
        };

        // Check if student is currently blocked
        if (student.isBlocked && student.blockedUntil is decimal) {
            if (currentTime < <decimal>student.blockedUntil) {
                decimal remainingTime = <decimal>student.blockedUntil - currentTime;
                decimal remainingMinutes = remainingTime / 60.0d;
                return {
                    allowed: false,
                    message: string `You are temporarily blocked from asking questions. Please wait ${remainingMinutes} more minutes.`,
                    cooldownUntil: student.blockedUntil,
                    alertLevel: "BLOCKED"
                };
            } else {
                // Unblock student
                student.isBlocked = false;
                student.blockedUntil = ();
            }
        }

        // Clean old questions from history (outside time window)
        decimal windowStart = currentTime - (TIME_WINDOW_MINUTES * 60.0d);
        student.questionHistory = student.questionHistory.filter(q => q.timestamp > windowStart);

        // Check if student has exceeded question limit
        int questionsInWindow = student.questionHistory.length();
        
        if (questionsInWindow >= MAX_QUESTIONS_PER_WINDOW) {
            // Block the student
            student.isBlocked = true;
            student.blockedUntil = currentTime + (COOLDOWN_MINUTES * 60.0d);
            students[request.studentId] = student;
            
            log:printWarn(string `Student ${student.name} (${student.id}) has been blocked for asking too many questions`);
            
            return {
                allowed: false,
                message: string `You have asked too many questions (${questionsInWindow}/${MAX_QUESTIONS_PER_WINDOW}) in the last ${TIME_WINDOW_MINUTES} minutes. Please wait ${COOLDOWN_MINUTES} minutes before asking again.`,
                cooldownUntil: student.blockedUntil,
                alertLevel: "RATE_LIMITED"
            };
        }

        // Add question to history
        QuestionHistory newQuestion = {
            timestamp: currentTime,
            question: request.question
        };
        student.questionHistory.push(newQuestion);
        student.totalQuestions += 1;
        students[request.studentId] = student;

        // Determine alert level
        string alertLevel = "NORMAL";
        if (questionsInWindow + 1 >= MAX_QUESTIONS_PER_WINDOW - 1) {
            alertLevel = "WARNING";
        }

        log:printInfo(string `Question accepted from ${student.name}: "${request.question}"`);

        return {
            allowed: true,
            message: "Question submitted successfully!",
            remainingQuestions: MAX_QUESTIONS_PER_WINDOW - (questionsInWindow + 1),
            alertLevel: alertLevel
        };
    }

    // Get student statistics
    resource function get students/[string studentId]/stats() returns Student|http:NotFound {
        Student? student = students[studentId];
        if (student is ()) {
            return http:NOT_FOUND;
        }
        return student;
    }

    // Get all students summary (for teacher dashboard)
    resource function get students/summary() returns record {string id; string name; int totalQuestions; boolean isBlocked; int questionsInWindow;}[] {
        decimal currentTime = <decimal>time:utcNow()[0];
        decimal windowStart = currentTime - (TIME_WINDOW_MINUTES * 60.0d);
        
        record {string id; string name; int totalQuestions; boolean isBlocked; int questionsInWindow;}[] summary = [];
        
        foreach Student student in students {
            int questionsInWindow = student.questionHistory.filter(q => q.timestamp > windowStart).length();
            summary.push({
                id: student.id,
                name: student.name,
                totalQuestions: student.totalQuestions,
                isBlocked: student.isBlocked,
                questionsInWindow: questionsInWindow
            });
        }
        
        return summary;
    }

    // Reset student's question history (admin function)
    resource function post students/[string studentId]/reset() returns string|http:NotFound {
        Student? student = students[studentId];
        if (student is ()) {
            return http:NOT_FOUND;
        }
        
        student.questionHistory = [];
        student.isBlocked = false;
        student.blockedUntil = ();
        students[studentId] = student;
        
        log:printInfo(string `Reset question history for student ${student.name}`);
        return string `Reset successful for student ${studentId}`;
    }

    // Get system configuration
    resource function get config() returns record {int maxQuestions; decimal timeWindowMinutes; decimal cooldownMinutes;} {
        return {
            maxQuestions: MAX_QUESTIONS_PER_WINDOW,
            timeWindowMinutes: TIME_WINDOW_MINUTES,
            cooldownMinutes: COOLDOWN_MINUTES
        };
    }

    // Health check endpoint
    resource function get health() returns string {
        return "Student Alert System is running!";
    }
}

// Utility function to get current students count
public function getActiveStudentsCount() returns int {
    return students.length();
}

// Function to clean up old data (call periodically)
public function cleanupOldData() {
    decimal currentTime = <decimal>time:utcNow()[0];
    decimal cleanupThreshold = currentTime - (24.0d * 60.0d * 60.0d); // 24 hours ago
    
    foreach string studentId in students.keys() {
        Student student = students[studentId] ?: {
            id: "", 
            name: "", 
            email: "", 
            questionHistory: [], 
            isBlocked: false, 
            totalQuestions: 0, 
            blockedUntil: ()
        };
        student.questionHistory = student.questionHistory.filter(q => q.timestamp > cleanupThreshold);
        students[studentId] = student;
    }
    
    log:printInfo("Cleaned up old question history data");
}