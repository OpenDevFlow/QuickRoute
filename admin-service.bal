import QuickRoute.db;
import QuickRoute.filters;
import QuickRoute.img;
import QuickRoute.password;
import QuickRoute.utils;

import ballerina/http;
import ballerina/io;
import ballerina/mime;
import ballerina/regex;
import ballerina/sql;
import ballerinax/mysql;

http:ClientConfiguration clientEPConfig = {
    cookieConfig: {
        enabled: true
    }
};
listener http:Listener adminEP = new (9092);

@http:ServiceConfig {
    cors: {
        allowOrigins: ["*"],
        allowMethods: ["GET", "POST", "PUT", "DELETE"],
        allowCredentials: true
    }
}

service /data on adminEP {

    private final mysql:Client connection;

    function init() returns error? {
        self.connection = db:getConnection();
    }

    function __deinit() returns sql:Error? {
        _ = checkpanic self.connection.close();
    }

    resource function get admin/getCountries/[string BALUSERTOKEN]() returns http:Unauthorized & readonly|error|http:Response {
        http:Response response = new;
        DBCountry[] countries = [];

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        stream<DBCountry, sql:Error?> countryStream = self.connection->query(`SELECT * FROM country`);
        sql:Error? streamError = countryStream.forEach(function(DBCountry country) {
            countries.push(country);
        });
        io:println(streamError);
        if streamError is sql:Error {
            check countryStream.close();
            return utils:setErrorResponse(response, "Error in retrieving countries");
        }
        response.setJsonPayload({
            "success": true,
            "content": countries.toJson()
        });
        return response;
    }

    resource function post admin/addDestination/[string BALUSERTOKEN](http:Request req) returns http:Response|error? {
        http:Response res = new;
        map<any> formData = {};

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return utils:returnResponseWithStatusCode(res, http:STATUS_UNAUTHORIZED, utils:UNAUTHORIZED_REQUEST);
        }

        if !utils:validateContent(req.getContentType()) {
            return utils:returnResponseWithStatusCode(res, http:STATUS_UNAUTHORIZED, utils:INVALID_CONTENT_TYPE);
        }

        map<any>|error multipartFormData = utils:parseMultipartFormData(req.getBodyParts(), formData);
        if multipartFormData is error {
            return utils:returnResponseWithStatusCode(res, http:STATUS_BAD_REQUEST, utils:INVALID_MULTIPART_REQUEST);
        }

        if !formData.hasKey("country_id") || !formData.hasKey("title") || !formData.hasKey("description") || !formData.hasKey("file") {
            return utils:returnResponseWithStatusCode(res, http:STATUS_BAD_REQUEST, utils:REQUIRED_FIELDS_MISSING);
        }

        string countryId = <string>formData["country_id"];
        string title = <string>formData["title"];
        string description = <string>formData["description"];

        if int:fromString(countryId) !is int {
            return utils:returnResponseWithStatusCode(res, http:STATUS_BAD_REQUEST, utils:INVALID_COUNTRY_ID);
        }

        DBCountry|sql:Error countryResult = self.connection->queryRow(`SELECT * FROM country WHERE id=${countryId}`);
        if countryResult is sql:NoRowsError {
            return utils:returnResponseWithStatusCode(res, http:STATUS_NOT_FOUND, utils:COUNTRY_NOT_FOUND);
        } else if countryResult is sql:Error {
            return utils:returnResponseWithStatusCode(res, http:STATUS_INTERNAL_SERVER_ERROR, utils:ERROR_FETCHING_COUNTRY);
        }

        DBDestination|sql:Error destinationResult = self.connection->queryRow(`SELECT * FROM destinations WHERE title = ${title} AND country_id=${countryId}`);
        if destinationResult is sql:NoRowsError {
            if formData["file"] is byte[] {
                string|error|io:Error? uploadImagee = img:uploadImagee(<byte[]>formData["file"], "destinations/", title);
                if uploadImagee is io:Error || uploadImagee is error {
                    return utils:returnResponseWithStatusCode(res, http:STATUS_INTERNAL_SERVER_ERROR, utils:ERROR_UPLOADING_IMAGE);
                }
                _ = check self.connection->execute(`INSERT INTO destinations (title, country_id, image, description) VALUES (${title}, ${countryId}, ${uploadImagee}, ${description})`);
                return utils:returnResponseWithStatusCode(res, http:STATUS_CREATED, "Successfully created destination", true);
            }
        } else if destinationResult is sql:Error {
            return utils:returnResponseWithStatusCode(res, http:STATUS_INTERNAL_SERVER_ERROR, utils:ERROR_FETCHING_DESTINATION);
        } else {
            return utils:returnResponseWithStatusCode(res, http:STATUS_CONFLICT, utils:DESTINATION_ALREADY_EXISTS);
        }
        return res;
    }

    resource function post admin/addLocation/[string BALUSERTOKEN](http:Request req) returns http:Unauthorized & readonly|error|http:Response {
        mime:Entity[] parts = check req.getBodyParts();
        http:Response response = new;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if !utils:validateContentType(req) {
            return utils:setErrorResponse(response, "Unsupported content type. Expected multipart/form-data.");
        }
        if parts.length() == 0 {
            return utils:setErrorResponse(response, "Request body is empty");
        }

        string destinationId = "";
        string tourTypeId = "";
        string title = "";
        string overview = "";
        boolean isImageInclude = false;
        foreach mime:Entity part in parts {
            string? dispositionName = part.getContentDisposition().name;
            string|mime:ParserError text = part.getText();
            if dispositionName is "destinationId" {
                if text is string {
                    destinationId = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving destinationId field");
                }
            } else if dispositionName is "tourTypeId" {
                if text is string {
                    tourTypeId = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving tourTypeId field");
                }
            } else if dispositionName is "title" {
                if text is string {
                    title = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving title field");
                }
            } else if dispositionName is "overview" {
                if text is string {
                    overview = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving overview field");
                }
            } else if dispositionName is "file" {
                if !utils:validateImageFile(part) {
                    return utils:setErrorResponse(response, "Invalid or unsupported image file type");
                }
                isImageInclude = true;
            }
        }

        if destinationId is "" || title is "" || overview is "" || tourTypeId is "" {
            return utils:setErrorResponse(response, "Parameters are empty");
        }
        if !isImageInclude {
            return utils:setErrorResponse(response, "Image is required");
        }

        if int:fromString(destinationId) !is int && int:fromString(tourTypeId) !is int {
            return utils:setErrorResponse(response, "Invalid destinationId or tourTypeId");
        }

        DBDestination|sql:Error desResult = self.connection->queryRow(`SELECT * FROM destinations WHERE id=${destinationId}`);
        DBTourType|sql:Error tourResult = self.connection->queryRow(`SELECT * FROM tour_type WHERE id=${tourTypeId}`);
        if desResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Destination not found");
        } else if desResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving destination");
        }
        if tourResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Tour type not found");
        } else if tourResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving tour type");
        }

        DBLocation|sql:Error locationResult = self.connection->queryRow(`SELECT * FROM  destination_location WHERE title=${title} AND destinations_id=${destinationId}`);
        if locationResult is sql:NoRowsError {
            string|error|io:Error? uploadedImagePath = img:uploadImage(req, "locations/", title);
            if uploadedImagePath !is string {
                return utils:setErrorResponse(response, "Error in uploading image");
            }
            _ = check self.connection->execute(`INSERT INTO destination_location (title,image,overview,tour_type_id,destinations_id) VALUES (${title},${uploadedImagePath},${overview},${tourTypeId},${destinationId})`);
            response.setJsonPayload({"success": true, "content": "Successfully uploaded destination location"});

        } else if locationResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving location");
        } else {
            return utils:setErrorResponse(response, "Destination location already exists");
        }
        return response;
    }

    resource function post admin/addOffer/[string BALUSERTOKEN](http:Request req) returns http:Unauthorized & readonly|error|http:Response {
        mime:Entity[] parts = check req.getBodyParts();
        http:Response response = new;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if !utils:validateContentType(req) {
            return utils:setErrorResponse(response, "Unsupported content type. Expected multipart/form-data.");
        }
        if parts.length() == 0 {
            return utils:setErrorResponse(response, "Request body is empty");
        }

        string destinationLocationId = "";
        string fromDate = "";
        string toDate = "";
        string title = "";
        boolean isImageInclude = false;
        foreach mime:Entity part in parts {
            string? dispositionName = part.getContentDisposition().name;
            string|mime:ParserError text = part.getText();
            if dispositionName is "destinationLocationId" {
                if text is string {
                    destinationLocationId = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving destination location id");
                }
            } else if dispositionName is "fromDate" {
                if text is string {
                    fromDate = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving from date");
                }
            } else if dispositionName is "toDate" {
                if text is string {
                    toDate = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving to date");
                }
            } else if dispositionName is "title" {
                if text is string {
                    title = text;
                } else {
                    return utils:setErrorResponse(response, "Error in retrieving title");
                }
            } else if dispositionName is "file" {
                if !utils:validateImageFile(part) {
                    return utils:setErrorResponse(response, "Invalid or unsupported image file type");
                }
                isImageInclude = true;
            }
        }

        string pattern = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$";
        boolean isValidFromDate = regex:matches(fromDate, pattern);
        boolean isValidToDate = regex:matches(toDate, pattern);

        if destinationLocationId is "" || fromDate is "" || toDate is "" || title is "" {
            return utils:setErrorResponse(response, "Missing required fields");
        }
        if !isImageInclude {
            return utils:setErrorResponse(response, "Image is required");
        }
        if int:fromString(destinationLocationId) !is int {
            return utils:setErrorResponse(response, "Invalid destination location id");
        }

        if isValidFromDate !is true && isValidToDate !is true {
            return utils:setErrorResponse(response, "Invalid date format");
        }

        DBLocation|sql:Error desLocResult = self.connection->queryRow(`SELECT * FROM destination_location WHERE id=${destinationLocationId}`);
        if desLocResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Destination location not found");
        } else if desLocResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving destination location");
        }

        DBOffer|sql:Error offerResult = self.connection->queryRow(`SELECT * FROM  offers WHERE title=${title} AND destination_location_id=${destinationLocationId} AND to_Date=${toDate} AND from_Date=${fromDate}`);
        if offerResult is sql:NoRowsError {
            string|error|io:Error? uploadedImagePath = img:uploadImage(req, "offers/", title);
            if uploadedImagePath !is string {
                return utils:setErrorResponse(response, "Error in uploading image");
            } else {
                _ = check self.connection->execute(`INSERT INTO offers (title,image,to_Date,from_Date,destination_location_id) VALUES (${title},${uploadedImagePath},${toDate},${fromDate},${destinationLocationId})`);
                response.setJsonPayload({"success": true, "content": "Successfully uploaded offer"});
            }
        } else if offerResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving offer");
        } else {
            return utils:setErrorResponse(response, "Offer already exists");
        }
        return response;
    }

    resource function get admin/getReviews/[string BALUSERTOKEN]() returns http:Unauthorized & readonly|http:Response|sql:Error|error {
        http:Response response = new;
        DBReview[] reviews = [];

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        stream<DBReview, sql:Error?> reviewStream = self.connection->query(`SELECT reviews.id AS review_id, user.first_name, user.last_name, user.email, reviews.review FROM reviews INNER JOIN user ON user.id = reviews.user_id`);
        sql:Error? streamError = reviewStream.forEach(function(DBReview review) {
            reviews.push(review);
        });
        if streamError is sql:Error {
            check reviewStream.close();
            return utils:setErrorResponse(response, "Error in retrieving reviews");
        }
        response.setJsonPayload({
            "success": true,
            "content": reviews.toJson()
        });
        return response;
    }

    resource function get admin/getOffers/[string BALUSERTOKEN]() returns http:Unauthorized & readonly|error|http:Response {
        http:Response response = new;
        DBOfferDetals[] offers = [];

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        stream<DBOfferDetals, sql:Error?> offersStream = self.connection->query(`SELECT offers.id AS offer_id, offers.from_Date, offers.to_Date, offers.title, offers.image, destination_location.title AS location_title, tour_type.type AS tour_type, destinations.title AS destination_title, country.name AS country_name FROM offers INNER JOIN destination_location ON destination_location.id = offers.destination_location_id INNER JOIN tour_type ON tour_type.id=destination_location.tour_type_id INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON country.id = destinations.country_id`);
        sql:Error? streamError = offersStream.forEach(function(DBOfferDetals offer) {
            offers.push(offer);
        });
        if streamError is sql:Error {
            check offersStream.close();
            return utils:setErrorResponse(response, "Error in retrieving offers");
        }
        response.setJsonPayload({
            "success": true,
            "content": offers.toJson()
        });
        return response;
    }

    resource function get admin/getLocations/[string BALUSERTOKEN]() returns http:Unauthorized & readonly|error|http:Response {
        http:Response response = new;
        json[] locationWithReviews = [];

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        stream<DBLocationDetails, sql:Error?> locationStream = self.connection->query(`
        SELECT destination_location.id AS location_id, 
               destination_location.title, 
               destination_location.image, 
               destination_location.overview, 
               tour_type.type AS tour_type, 
               destinations.title AS destination_title, 
               country.name AS country_name 
        FROM destination_location 
        INNER JOIN tour_type ON tour_type.id = destination_location.tour_type_id 
        INNER JOIN destinations ON destinations.id = destination_location.destinations_id 
        INNER JOIN country ON country.id = destinations.country_id
    `);

        sql:Error|() locationStreamError = locationStream.forEach(function(DBLocationDetails location) {
            LocationReviewDetails[] reviews = [];

            stream<LocationReviewDetails, sql:Error?> reviewStream = self.connection->query(`
            SELECT ratings.id AS rating_id, 
                   ratings.rating_count, 
                   ratings.review_img, 
                   ratings.review, 
                   user.first_name, 
                   user.last_name, 
                   user.email 
            FROM ratings 
            INNER JOIN user ON user.id = ratings.user_id 
            WHERE destination_location_id = ${location.location_id}
        `);
            sql:Error? reviewStreamError = reviewStream.forEach(function(LocationReviewDetails review) {
                reviews.push(review);
            });

            if reviewStreamError is sql:Error {
                return ();
            }

            json returnObject = {
                location: location.toJson(),
                reviews: reviews.toJson()
            };
            locationWithReviews.push(returnObject);
        });

        if locationStreamError is sql:Error {
            check locationStream.close();
            return utils:setErrorResponse(response, "Error in retrieving locations");
        }

        check locationStream.close();

        response.setJsonPayload({
            "success": true,
            "content": locationWithReviews
        });
        return response;
    }

    resource function get admin/getDestinations/[string BALUSERTOKEN]() returns http:Unauthorized & readonly|error|http:Response {
        http:Response response = new;
        DBDestinationDetails[] destinations = [];

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        stream<DBDestinationDetails, sql:Error?> destinationStream = self.connection->query(`SELECT destinations.id AS destination_id, destinations.title, destinations.image, destinations.description, country.name AS country_name FROM destinations INNER JOIN  country ON country.id = destinations.country_id`);
        sql:Error? streamError = destinationStream.forEach(function(DBDestinationDetails destination) {
            destinations.push(destination);
        });
        if streamError is sql:Error {
            check destinationStream.close();
            return utils:setErrorResponse(response, "Error in retrieving destinations");
        }
        response.setJsonPayload({
            "success": true,
            "content": destinations.toJson()
        });
        return response;
    }

    resource function put admin/updatePassword/[string BALUSERTOKEN](@http:Payload RequestPassword payload) returns http:Unauthorized & readonly|error|http:Response {
        http:Response response = new;
        map<string> errorMsg = {};
        boolean errorFlag = false;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if payload.user_id is "" {
            errorFlag = true;
            errorMsg["user_id"] = "User ID required";
        }
        if payload.new_password is "" {
            errorFlag = true;
            errorMsg["new_pw"] = "New password required";
        }
        if payload.old_password is "" {
            errorFlag = true;
            errorMsg["old_pw"] = "Old password required";
        }

        if errorFlag {
            return utils:setErrorResponse(response, errorMsg.toJson());
        }

        DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM admin  WHERE id = ${payload.user_id}`);
        if result is DBUser {
            boolean isOldPwVerify = password:verifyHmac(payload.old_password, result.password);
            if isOldPwVerify !is true {
                return utils:setErrorResponse(response, "Old password is incorrect");
            }
            string newHashedPw = password:generateHmac(payload.new_password);
            sql:ExecutionResult|sql:Error updateResult = self.connection->execute(`UPDATE admin SET password = ${newHashedPw} WHERE id  = ${payload.user_id}`);
            if updateResult is sql:Error {
                return utils:setErrorResponse(response, "Error updating password");
            }
            response.setJsonPayload({
                "success": true,
                "content": "Password updated successfully"
            });
        } else {
            return utils:setErrorResponse(response, "User not found");
        }

        return response;
    }

    resource function put admin/updateDestination/[string BALUSERTOKEN](http:Request req) returns http:Unauthorized & readonly|error|http:Response {
        mime:Entity[] parts = check req.getBodyParts();
        http:Response response = new;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if !utils:validateContentType(req) {
            return utils:setErrorResponse(response, "Unsupported content type. Expected multipart/form-data.");
        }
        if parts.length() == 0 {
            return utils:setErrorResponse(response, "Request body is empty");
        }
        string destinationId = "";
        string countryId = "";
        string title = "";
        string description = "";
        boolean isImageInclude = false;
        foreach mime:Entity part in parts {
            string? dispositionName = part.getContentDisposition().name;
            string|mime:ParserError text = part.getText();
            if dispositionName is "destinationId" {
                if text is string {
                    destinationId = text;
                }
            } else if dispositionName is "country_id" {
                if text is string {
                    countryId = text;
                }
            } else if dispositionName is "title" {
                if text is string {
                    title = text;
                }
            } else if dispositionName is "description" {
                if text is string {
                    description = text;
                }
            } else if dispositionName is "file" {
                if !utils:validateImageFile(part) {
                    return utils:setErrorResponse(response, "Invalid or unsupported image file type");
                }
                isImageInclude = true;
            }
        }

        if destinationId is "" {
            return utils:setErrorResponse(response, "Destination ID is required");
        }

        DBDestination|sql:Error desResult = self.connection->queryRow(`SELECT * FROM destinations WHERE id=${destinationId}`);
        if desResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Destination not found");
        } else if desResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving destination");
        }

        if desResult is DBDestination {
            sql:ParameterizedQuery[] setClauses = [];
            if countryId != "" {
                setClauses.push(<sql:ParameterizedQuery>`country_id = ${countryId}`);
            }
            if title != "" {
                setClauses.push(`title = ${title}`);
            }
            if description != "" {
                setClauses.push(<sql:ParameterizedQuery>`description = ${description}`);
            }
            if isImageInclude {
                boolean|error isDeleteImage = img:deleteImageFile(desResult.image);
                if isDeleteImage is false || isDeleteImage is error {
                    return utils:setErrorResponse(response, "Error in deleting image");
                }
                string imageName = title != "" ? title : desResult.title;
                string|error|io:Error? uploadedImage = img:uploadImage(req, "destinations/", imageName);

                if uploadedImage is error {
                    return utils:setErrorResponse(response, "Error in uploading image");
                }
                setClauses.push(<sql:ParameterizedQuery>`image = ${uploadedImage}`);
            }

            if setClauses.length() > 0 {
                sql:ParameterizedQuery setPart = ``;
                boolean isFirst = true;
                foreach sql:ParameterizedQuery clause in setClauses {
                    if !isFirst {
                        setPart = sql:queryConcat(setPart, `, `, clause);
                    } else {
                        setPart = sql:queryConcat(setPart, clause);
                        isFirst = false;
                    }
                }
                sql:ParameterizedQuery queryConcat = sql:queryConcat(`UPDATE destinations SET `, setPart, ` WHERE id = ${destinationId} `);
                sql:ExecutionResult|sql:Error updateResult = self.connection->execute(queryConcat);
                if updateResult is sql:Error {
                    return utils:setErrorResponse(response, "Error in updating destination");
                }
                response.setJsonPayload({"success": "Successfully updated the destination"});
            } else {
                return utils:setErrorResponse(response, "No valid fields to update");
            }
        }

        return response;
    }

    resource function put admin/updateOffer/[string BALUSERTOKEN](http:Request req) returns http:Unauthorized & readonly|error|http:Response {
        mime:Entity[] parts = check req.getBodyParts();
        http:Response response = new;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if !utils:validateContentType(req) {
            return utils:setErrorResponse(response, "Unsupported content type. Expected multipart/form-data.");
        }
        if parts.length() == 0 {
            return utils:setErrorResponse(response, "Request body is empty");
        }
        string offerId = "";
        string fromDate = "";
        string title = "";
        string toDate = "";
        string locationId = "";
        boolean isImageInclude = false;
        foreach mime:Entity part in parts {
            string? dispositionName = part.getContentDisposition().name;
            string|mime:ParserError text = part.getText();
            if dispositionName is "offerId" {
                if text is string {
                    offerId = text;
                }
            } else if dispositionName is "fromDate" {
                if text is string {
                    fromDate = text;
                }
            } else if dispositionName is "title" {
                if text is string {
                    title = text;
                }
            } else if dispositionName is "toDate" {
                if text is string {
                    toDate = text;
                }
            } else if dispositionName is "locationId" {
                if text is string {
                    locationId = text;
                }
            } else if dispositionName is "file" {
                if !utils:validateImageFile(part) {
                    return utils:setErrorResponse(response, "Invalid or unsupported image file type");
                }
                isImageInclude = true;
            }
        }

        if offerId is "" {
            return utils:setErrorResponse(response, "Offer ID is required");
        }

        DBOffer|sql:Error offerResult = self.connection->queryRow(`SELECT * FROM offers WHERE id=${offerId}`);
        if offerResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Offer not found");
        } else if offerResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving offer");
        }

        if offerResult is DBOffer {
            sql:ParameterizedQuery[] setClauses = [];
            if locationId != "" {
                setClauses.push(<sql:ParameterizedQuery>`destination_location_id = ${locationId}`);
            }
            if title != "" {
                setClauses.push(`title = ${title}`);
            }
            if fromDate != "" {
                boolean isValidFromDate = regex:matches(fromDate, utils:DATETIME_REGEX);
                if isValidFromDate !is true {
                    return utils:setErrorResponse(response, "Invalid date format");
                }
                setClauses.push(<sql:ParameterizedQuery>`from_Date = ${fromDate}`);
            }
            if toDate != "" {
                boolean isValidToDate = regex:matches(toDate, utils:DATETIME_REGEX);
                if isValidToDate !is true {
                    return utils:setErrorResponse(response, "Invalid date format");
                }
                setClauses.push(<sql:ParameterizedQuery>`to_Date = ${toDate}`);
            }
            if isImageInclude {
                boolean|error isDeleteImage = img:deleteImageFile(offerResult.image);
                if isDeleteImage is false || isDeleteImage is error {
                    return utils:setErrorResponse(response, "Error in deleting image");
                }
                string imageName = title != "" ? title : offerResult.title;
                string|error|io:Error? uploadedImage = img:uploadImage(req, "offers/", imageName);

                if uploadedImage is error {
                    return utils:setErrorResponse(response, "Error in uploading image");
                }
                setClauses.push(<sql:ParameterizedQuery>`image = ${uploadedImage}`);
            }

            if setClauses.length() > 0 {
                sql:ParameterizedQuery setPart = ``;
                boolean isFirst = true;
                foreach sql:ParameterizedQuery clause in setClauses {
                    if !isFirst {
                        setPart = sql:queryConcat(setPart, `, `, clause);
                    } else {
                        setPart = sql:queryConcat(setPart, clause);
                        isFirst = false;
                    }
                }
                sql:ParameterizedQuery queryConcat = sql:queryConcat(`UPDATE offers SET `, setPart, ` WHERE id = ${offerId} `);
                sql:ExecutionResult|sql:Error updateResult = self.connection->execute(queryConcat);
                if updateResult is sql:Error {
                    return utils:setErrorResponse(response, "Error in updating offer");
                }
                response.setJsonPayload({"success": true, "content": "Successfully updated the offer"});
            } else {
                return utils:setErrorResponse(response, "No valid fields to update");
            }
        }
        return response;
    }

    resource function put admin/updateLocation/[string BALUSERTOKEN](http:Request req) returns http:Unauthorized & readonly|error|http:Response {
        mime:Entity[] parts = check req.getBodyParts();
        http:Response response = new;

        if (!check filters:requestFilterAdmin(BALUSERTOKEN)) {
            return http:UNAUTHORIZED;
        }

        if !utils:validateContentType(req) {
            return utils:setErrorResponse(response, "Unsupported content type. Expected multipart/form-data.");
        }
        if parts.length() == 0 {
            return utils:setErrorResponse(response, "Request body is empty");
        }
        string locationId = "";
        string tourTypeId = "";
        string title = "";
        string overview = "";
        string destinationId = "";
        boolean isImageInclude = false;
        foreach mime:Entity part in parts {
            string? dispositionName = part.getContentDisposition().name;
            string|mime:ParserError text = part.getText();
            if dispositionName is "locationId" {
                if text is string {
                    locationId = text;
                }
            } else if dispositionName is "tourTypeId" {
                if text is string {
                    tourTypeId = text;
                }
            } else if dispositionName is "title" {
                if text is string {
                    title = text;
                }
            } else if dispositionName is "overview" {
                if text is string {
                    overview = text;
                }
            } else if dispositionName is "destinationId" {
                if text is string {
                    destinationId = text;
                }
            } else if dispositionName is "file" {
                if !utils:validateImageFile(part) {
                    return utils:setErrorResponse(response, "Invalid or unsupported image file type");
                }
                isImageInclude = true;
            }
        }

        if locationId is "" {
            return utils:setErrorResponse(response, "Location ID is required");
        }

        DBLocation|sql:Error locationResult = self.connection->queryRow(`SELECT * FROM destination_location WHERE id=${locationId}`);
        if locationResult is sql:NoRowsError {
            return utils:setErrorResponse(response, "Destination location not found");
        } else if locationResult is sql:Error {
            return utils:setErrorResponse(response, "Error in retrieving destination location");
        }

        if locationResult is DBLocation {
            sql:ParameterizedQuery[] setClauses = [];
            if overview != "" {
                setClauses.push(<sql:ParameterizedQuery>`overview = ${overview}`);
            }
            if title != "" {
                setClauses.push(`title = ${title}`);
            }
            if tourTypeId != "" {
                setClauses.push(<sql:ParameterizedQuery>`tour_type_id = ${tourTypeId}`);
            }
            if tourTypeId != "" {
                setClauses.push(<sql:ParameterizedQuery>`destinations_id = ${destinationId}`);
            }
            if isImageInclude {
                boolean|error isDeleteImage = img:deleteImageFile(locationResult.image);
                if isDeleteImage is false || isDeleteImage is error {
                    return utils:setErrorResponse(response, "Error in deleting image");
                }
                string imageName = title != "" ? title : locationResult.title;
                string|error|io:Error? uploadedImage = img:uploadImage(req, "locations/", imageName);

                if uploadedImage is error {
                    return utils:setErrorResponse(response, "Error in uploading image");
                }
                setClauses.push(<sql:ParameterizedQuery>`image = ${uploadedImage}`);
            }

            if setClauses.length() > 0 {
                sql:ParameterizedQuery setPart = ``;
                boolean isFirst = true;
                foreach sql:ParameterizedQuery clause in setClauses {
                    if !isFirst {
                        setPart = sql:queryConcat(setPart, `, `, clause);
                    } else {
                        setPart = sql:queryConcat(setPart, clause);
                        isFirst = false;
                    }
                }
                sql:ParameterizedQuery queryConcat = sql:queryConcat(`UPDATE destination_location SET `, setPart, ` WHERE id = ${locationId} `);
                sql:ExecutionResult|sql:Error updateResult = self.connection->execute(queryConcat);
                if updateResult is sql:Error {
                    return utils:setErrorResponse(response, "Error in updating destination location");
                }
                response.setJsonPayload({"success": "Successfully updated the destination location"});
            } else {
                return utils:setErrorResponse(response, "No valid fields to update");
            }
        }
        return response;
    }

}
