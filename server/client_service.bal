import QuickRoute.OpenAI;
import QuickRoute.db;
import QuickRoute.email;
import QuickRoute.filters;
import QuickRoute.img;
import QuickRoute.jwt;
import QuickRoute.time;
import QuickRoute.utils;

import ballerina/data.jsondata;
import ballerina/http;
import ballerina/io;
import ballerina/sql;
import ballerinax/mysql;

listener http:Listener clientSideEP = new (9093);

@http:ServiceConfig {
    cors: {
        allowOrigins: ["*"],
        allowMethods: ["GET", "POST", "PUT", "DELETE"],
        allowCredentials: true
    }
}

service /clientData on clientSideEP {

    private final mysql:Client connection;

    function init() returns error? {
        self.connection = db:getConnection();
    }

    function __deinit() returns sql:Error? {
        _ = checkpanic self.connection.close();
    }

    resource function get plan/create/[string BALUSERTOKEN](string planName) returns http:Response|error {
        http:Response backendResponse = new;
        if planName == "" {
            backendResponse.setJsonPayload({success: false, message: "plan name is required"});
            backendResponse.statusCode = http:STATUS_BAD_REQUEST;
            return backendResponse;
        } else if (planName.length() > 50) {
            backendResponse.setJsonPayload({success: false, message: "plan name is too long"});
            backendResponse.statusCode = http:STATUS_BAD_REQUEST;
            return backendResponse;
        } else {
            json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
            UserDTO payload = check jsondata:parseString(decodeJWT.toString());
            if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
                sql:ExecutionResult executionResult = check self.connection->execute(`INSERT INTO  trip_plan (plan_name) VALUES (${planName})`);
                int lastInsertId = <int>executionResult.lastInsertId;
                DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
                if result is sql:NoRowsError {
                    backendResponse.setJsonPayload({success: false, message: "user not found"});
                    backendResponse.statusCode = http:STATUS_NOT_FOUND;
                    return backendResponse;
                } else if result is sql:Error {
                    backendResponse.setJsonPayload({success: false, message: "database error"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                } else {
                    anydata|sql:Error existingPlan = self.connection->queryRow(`SELECT * FROM user_has_trip_plans INNER JOIN trip_plan ON user_has_trip_plans.trip_plan_id = trip_plan.id WHERE plan_name = ${planName} AND user_id = ${result.id}`);
                    if existingPlan is sql:NoRowsError {
                        _ = check self.connection->execute(`INSERT INTO  user_has_trip_plans (trip_plan_id,user_id) VALUES (${lastInsertId},${result.id})`);
                    } else {
                        backendResponse.setJsonPayload({success: false, message: "plan already exists"});
                        backendResponse.statusCode = http:STATUS_CONFLICT;
                        return backendResponse;
                    }
                }
                backendResponse.setJsonPayload({success: true, message: "plan created", planName, planId: lastInsertId});
                backendResponse.statusCode = http:STATUS_CREATED;
                return backendResponse;
            } else {
                backendResponse.setJsonPayload({success: false, message: "token expired"});
                backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
                return backendResponse;
            }
        }
    }

    resource function get plan/allPlans/[string BALUSERTOKEN]() returns json|error|http:Response {
        http:Response backendResponse = new;
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else if result is sql:Error {
                backendResponse.setJsonPayload({success: false, message: "database error"});
                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                return backendResponse;
            } else {
                stream<UserHasPlans, sql:Error?> user_has_plans_stream = self.connection->query(`SELECT trip_plan.id AS plan_id,trip_plan.plan_name,user_id FROM user_has_trip_plans INNER JOIN trip_plan ON user_has_trip_plans.trip_plan_id = trip_plan.id  WHERE user_id = ${result.id}`);
                UserHasPlans[] QuickRouteUserHasPlans = [];
                check from UserHasPlans user_has_plan in user_has_plans_stream
                    do {
                        QuickRouteUserHasPlans.push(user_has_plan);
                    };
                check user_has_plans_stream.close();
                if (QuickRouteUserHasPlans.length() == 0) {
                    backendResponse.setJsonPayload({success: false, message: "no plans found"});
                    backendResponse.statusCode = http:STATUS_NOT_FOUND;
                    return backendResponse;
                } else {
                    backendResponse.setJsonPayload({success: true, plans: QuickRouteUserHasPlans.toJson()});
                    backendResponse.statusCode = http:STATUS_OK;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function put plan/rename/[string BALUSERTOKEN](@http:Payload PlanRename newPlanName) returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else if result is sql:Error {
                backendResponse.setJsonPayload({success: false, message: "database error"});
                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                return backendResponse;
            } else {
                UserHasPlans|sql:Error tripPlanResult = self.connection->queryRow(`SELECT trip_plan.id AS plan_id,trip_plan.plan_name,user_id FROM user_has_trip_plans INNER JOIN trip_plan ON user_has_trip_plans.trip_plan_id = trip_plan.id  WHERE user_id = ${result.id} AND trip_plan_id = ${newPlanName.plan_id}`);
                if tripPlanResult is sql:NoRowsError {
                    backendResponse.setJsonPayload({success: false, message: "plan not found"});
                    backendResponse.statusCode = http:STATUS_NOT_FOUND;
                    return backendResponse;
                } else if tripPlanResult is sql:Error {
                    backendResponse.setJsonPayload({success: false, message: "database error"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                } else {
                    _ = check self.connection->execute(`UPDATE trip_plan SET plan_name = (${newPlanName.new_name}) WHERE id = ${newPlanName.plan_id}`);
                    backendResponse.setJsonPayload({success: true, message: "plan renamed"});
                    backendResponse.statusCode = http:STATUS_OK;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function get plan/userPlan/addDestination/[string BALUSERTOKEN](int plan_id, int destination_id) returns error|http:Response {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = ${payload.email}`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else {
                if result is DBUser {
                    DBLocation|sql:Error destination = self.connection->queryRow(`SELECT * FROM destination_location WHERE id = ${destination_id}`);
                    if destination is sql:NoRowsError {
                        backendResponse.setJsonPayload({success: false, message: "destination not found"});
                        backendResponse.statusCode = http:STATUS_NOT_FOUND;
                        return backendResponse;
                    } else if destination is sql:Error {
                        backendResponse.setJsonPayload({success: false, message: "database error"});
                        backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                        return backendResponse;
                    } else {
                        DBPlan|sql:Error plan = self.connection->queryRow(`SELECT * FROM trip_plan  WHERE id = ${plan_id}`);
                        if plan is sql:NoRowsError {
                            backendResponse.setJsonPayload({success: false, message: "plan not found"});
                            backendResponse.statusCode = http:STATUS_NOT_FOUND;
                            return backendResponse;
                        } else if plan is sql:Error {
                            backendResponse.setJsonPayload({success: false, message: "database error"});
                            backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                            return backendResponse;
                        } else {
                            plan_has_des|sql:Error queryRow = self.connection->queryRow(`SELECT * FROM plan_has_des WHERE destination_location_id = ${destination_id} AND trip_plan_id = ${plan_id}`);
                            if queryRow is sql:NoRowsError {
                                _ = check self.connection->execute(`INSERT INTO plan_has_des (trip_plan_id,destination_location_id) VALUES  (${plan_id},${destination_id})`);
                                backendResponse.setJsonPayload({success: true, message: "destination added"});
                                backendResponse.statusCode = http:STATUS_OK;
                                return backendResponse;
                            } else if queryRow is sql:Error {
                                backendResponse.setJsonPayload({success: false, message: "database error"});
                                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                                return backendResponse;
                            } else {
                                backendResponse.setJsonPayload({success: false, message: "destination already added"});
                                backendResponse.statusCode = http:STATUS_CONFLICT;
                                return backendResponse;
                            }
                        }
                    }
                } else {
                    backendResponse.setJsonPayload({success: false, message: "database error"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function post site/review/[string BALUSERTOKEN](@http:Payload siteReview SiteReview) returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else {
                if result is DBUser {
                    _ = check self.connection->execute(`INSERT INTO reviews (review, user_id) VALUES (${SiteReview.review},${result.id})`);
                    backendResponse.setJsonPayload({success: true, message: "review added"});
                    backendResponse.statusCode = http:STATUS_OK;
                    return backendResponse;
                } else {
                    backendResponse.setJsonPayload({success: false, message: "database error"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function get user/wishlist/[string BALUSERTOKEN]() returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else if result is sql:Error {
                backendResponse.setJsonPayload({success: false, message: "database error"});
                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                return backendResponse;
            } else {
                stream<UserWishlist, sql:Error?> user_wishlist_strem = self.connection->query(`SELECT destination_location.id AS destinations_id,destination_location.title AS destination_location_title,destinations.title AS destination_title,country.name AS country_name,ROUND(AVG(ratings.rating_count),1) AS average_rating,COUNT(ratings.rating_count) AS total_ratings,destination_location.image AS image,destination_location.overview FROM wishlist INNER JOIN destination_location ON destination_location.id = wishlist.destination_location_id INNER JOIN tour_type ON destination_location.tour_type_id = tour_type.id INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON destinations.country_id = country.id LEFT JOIN ratings ON destination_location.id = ratings.destination_location_id WHERE wishlist.user_id = ${result.id} GROUP BY destination_location.id, destination_location.title, country.name`);
                UserWishlist[] userWishlist = [];
                check from UserWishlist user_wishlist in user_wishlist_strem
                    do {
                        userWishlist.push(user_wishlist);
                    };
                backendResponse.setJsonPayload({success: true, wishlist: userWishlist.toJson()});
                backendResponse.statusCode = http:STATUS_OK;
                return backendResponse;
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function get user/wishlist/add/[string BALUSERTOKEN](int destinations_id) returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else {
                DBLocation|sql:Error destination = self.connection->queryRow(`SELECT * FROM destination_location WHERE id = (${destinations_id})`);
                if destination is sql:NoRowsError {
                    backendResponse.setJsonPayload({success: false, message: "destination not found"});
                    backendResponse.statusCode = http:STATUS_NOT_FOUND;
                    return backendResponse;
                } else {
                    if destination is DBLocation {
                        if result is DBUser {
                            _ = check self.connection->execute(`INSERT INTO wishlist (user_id,destination_location_id) VALUES (${result.id},${destination.id})`);
                            backendResponse.setJsonPayload({success: true, message: "destination added to wishlist"});
                            backendResponse.statusCode = http:STATUS_OK;
                            return backendResponse;
                        } else {
                            backendResponse.setJsonPayload({success: false, message: "database error"});
                            backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                            return backendResponse;
                        }
                    } else {
                        backendResponse.setJsonPayload({success: false, message: "database error"});
                        backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                        return backendResponse;
                    }
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }

    resource function delete user/wishlist/removeDestination/[string BALUSERTOKEN](@http:Payload removeWishList RemoveDestination) returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else {
                if result is DBUser {
                    wishlist|sql:Error wishlistRow = self.connection->queryRow(`SELECT * FROM wishlist WHERE user_id = (${result.id}) AND destination_location_id = ${RemoveDestination.destinations_id}`);
                    if wishlistRow is sql:NoRowsError {
                        backendResponse.setJsonPayload({success: false, message: "destination not found in wishlist"});
                        backendResponse.statusCode = http:STATUS_NOT_FOUND;
                        return backendResponse;
                    } else if wishlistRow is sql:Error {
                        backendResponse.setJsonPayload({success: false, message: "database error"});
                        backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                        return backendResponse;
                    } else {
                        _ = check self.connection->execute(`DELETE FROM wishlist WHERE user_id = ${result.id} AND destination_location_id = ${RemoveDestination.destinations_id}`);
                        backendResponse.setJsonPayload({success: true, message: "destination removed from wishlist"});
                        backendResponse.statusCode = http:STATUS_OK;
                        return backendResponse;
                    }
                } else {
                    backendResponse.setJsonPayload({success: false, message: "database error"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }

    }

    resource function post user/rating/addLocationReview/[string BALUSERTOKEN](http:Request req) returns http:Response|error? {
        http:Response backendResponse = new;
        map<any> formData = {};
        boolean|error requestFilterUser = filters:requestFilterUser(BALUSERTOKEN);
        if requestFilterUser is boolean && requestFilterUser == false {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_UNAUTHORIZED, "Token expired");
        }
        if !utils:validateContentType(req.getContentType()) {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_UNSUPPORTED_MEDIA_TYPE, utils:INVALID_CONTENT_TYPE);
        }

        map<any>|error multipartFormData = utils:parseMultipartFormData(req.getBodyParts(), formData);
        if multipartFormData is error {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_BAD_REQUEST, utils:INVALID_MULTIPART_REQUEST);
        }

        if !formData.hasKey("email") || !formData.hasKey("locationId") || !formData.hasKey("comment") || !formData.hasKey("rating") {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_BAD_REQUEST, utils:REQUIRED_FIELDS_MISSING);
        }

        string email = <string>formData["email"];
        string locationId = <string>formData["locationId"];
        string comment = <string>formData["comment"];
        string rating = <string>formData["rating"];

        if int:fromString(locationId) !is int {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_BAD_REQUEST, utils:INVALID_LOCATION_ID);
        }

        if int:fromString(rating) !is int {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_BAD_REQUEST, utils:INVALID_LOCATION_ID);
        }

        DBLocation|sql:Error locationResult = self.connection->queryRow(`SELECT * FROM destination_location WHERE id=${locationId}`);
        if locationResult is sql:NoRowsError {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_NOT_FOUND, utils:DESTINATION_LOCATION_NOT_FOUND);
        } else if locationResult is sql:Error {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_INTERNAL_SERVER_ERROR, utils:DATABASE_ERROR);
        }

        DBUser|sql:Error userResult = self.connection->queryRow(`SELECT * FROM user WHERE email=${email}`);
        if userResult is sql:NoRowsError {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_NOT_FOUND, utils:USER_NOT_FOUND);
        } else if userResult is sql:Error {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_INTERNAL_SERVER_ERROR, utils:DATABASE_ERROR);
        }

        if userResult is DBUser {
            if formData.hasKey("file") {
                if formData["file"] is byte[] {
                    string|error|io:Error? uploadImage = img:uploadImage(<byte[]>formData["file"], "ratings/", userResult.first_name + locationId.toString());
                    if uploadImage is io:Error || uploadImage is error {
                        return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_INTERNAL_SERVER_ERROR, utils:ERROR_UPLOADING_IMAGE);
                    }
                    _ = check self.connection->execute(`INSERT INTO ratings (rating_count, user_id, review, review_img, destination_location_id) VALUES (${rating}, ${userResult.id}, ${comment}, ${uploadImage}, ${locationId})`);
                    return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_CREATED, utils:REVIEW_CREATED, true);
                }
            } else {
                _ = check self.connection->execute(`INSERT INTO ratings (rating_count, user_id, review, destination_location_id) VALUES (${rating}, ${userResult.id}, ${comment}, ${locationId})`);
                return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_CREATED, utils:REVIEW_CREATED, true);
            }
        }

        return backendResponse;
    }

    resource function get destinationLocations() returns http:Response|error {
        http:Response backendResponse = new;
        stream<DBLocationDetailsWithRatings, sql:Error?> dbDestination_stream = self.connection->query(`SELECT destination_location.id AS location_id, destination_location.title AS title, destination_location.image AS image, destination_location.overview AS overview, tour_type.type AS tour_type, destinations.title AS destination_title, country.name AS country_name, COUNT(ratings.rating_count) AS total_ratings, ROUND(AVG(ratings.rating_count), 1) AS average_rating FROM destination_location INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON destinations.country_id = country.id INNER JOIN tour_type ON destination_location.tour_type_id = tour_type.id LEFT JOIN ratings ON destination_location.id = ratings.destination_location_id GROUP BY destination_location.id, destination_location.title, destination_location.image, destination_location.overview, tour_type.type, destinations.title, country.name`);
        DBLocationDetailsWithRatings[] QuickRouteDestination = [];
        check from DBLocationDetailsWithRatings dbDestination in dbDestination_stream
            do {
                QuickRouteDestination.push(dbDestination);
            };
        check dbDestination_stream.close();
        backendResponse.setJsonPayload(QuickRouteDestination.toJson());
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function get destinationLocation(string destination_id) returns http:Response|error {
        http:Response backendResponse = new;
        DBLocationDetailsWithRatings|sql:Error dbDestinationLocation = self.connection->queryRow(`SELECT destination_location.id AS location_id, destination_location.title AS title, destination_location.image AS image, destination_location.overview AS overview, tour_type.type AS tour_type, destinations.title AS destination_title, country.name AS country_name, COUNT(ratings.rating_count) AS total_ratings, ROUND(AVG(ratings.rating_count), 1) AS average_rating FROM destination_location INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON destinations.country_id = country.id INNER JOIN tour_type ON destination_location.tour_type_id = tour_type.id LEFT JOIN ratings ON destination_location.id = ratings.destination_location_id WHERE destination_location.id = ${destination_id}  GROUP BY destination_location.id, destination_location.title, destination_location.image, destination_location.overview, tour_type.type, destinations.title, country.name `);
        DBLocationDetailsWithRatings[] QuickRouteDestination = [];
        if dbDestinationLocation is DBLocationDetailsWithRatings {
            QuickRouteDestination.push(dbDestinationLocation);
            stream<DBLocationDetailsWithRatings, sql:Error?> dbRelatedLocations_stream = self.connection->query(`SELECT destination_location.id AS location_id, destination_location.title AS title, destination_location.image AS image, destination_location.overview AS overview,  tour_type.type AS tour_type, destinations.title AS destination_title, country.name AS country_name, COUNT(ratings.rating_count) AS total_ratings, ROUND(AVG(ratings.rating_count), 1) AS average_rating FROM  destination_location  INNER JOIN  destinations ON destinations.id = destination_location.destinations_id INNER JOIN  country ON destinations.country_id = country.id INNER JOIN  tour_type ON destination_location.tour_type_id = tour_type.id LEFT JOIN  ratings ON destination_location.id = ratings.destination_location_id WHERE tour_type.type = ${dbDestinationLocation.tour_type}  AND destinations.title = ${dbDestinationLocation.destination_title} GROUP BY destination_location.id,  destination_location.title, destination_location.image, destination_location.overview, tour_type.type, destinations.title, country.name LIMIT 4`);
            DBLocationDetailsWithRatings[] RelatedLocations = [];
            check from DBLocationDetailsWithRatings dbRelatedLocation in dbRelatedLocations_stream
                do {
                    RelatedLocations.push(dbRelatedLocation);
                };
            check dbRelatedLocations_stream.close();
            json objectRes = {
                "locations": QuickRouteDestination.toJson(),
                "relatedLocations": RelatedLocations.toJson()
            };
            backendResponse.setJsonPayload(objectRes.toJson());
            backendResponse.statusCode = http:STATUS_OK;
        }
        return backendResponse;
    }

    resource function get homepage() returns error|http:Response {
        http:Response backendResponse = new;
        stream<DBLocationDetailsWithReview, sql:Error?> dbDestination_stream = self.connection->query(`SELECT destination_location.id AS destination_id,destination_location.title,destination_location.overview ,country.name AS country_name,tour_type.type AS tour_type,COUNT(ratings.id) AS total_reviews,destination_location.image , ROUND(AVG(ratings.rating_count),1)AS average_rating , destinations.title AS destination_title FROM ratings INNER JOIN destination_location ON ratings.destination_location_id = destination_location.id INNER JOIN destinations ON destination_location.destinations_id = destinations.id INNER JOIN country ON destinations.country_id = country.id INNER JOIN tour_type ON destination_location.tour_type_id = tour_type.id GROUP BY destination_location.id, destination_location.title, destination_location.overview, country.name, tour_type.type ORDER BY total_reviews DESC LIMIT 10`);
        DBLocationDetailsWithReview[] QuickRouteDestination = [];
        check from DBLocationDetailsWithReview dbDestination in dbDestination_stream
            do {
                QuickRouteDestination.push(dbDestination);
            };
        check dbDestination_stream.close();
        stream<userAddedSiteReview, sql:Error?> userAddedReview = self.connection->query(`SELECT first_name,last_name,email,review ,(SELECT COUNT(reviews.id) FROM reviews) AS total_review_count FROM  reviews INNER JOIN user ON reviews.user_id = user.id `);
        userAddedSiteReview[] userAddedReviews = [];
        check from userAddedSiteReview userReview in userAddedReview
            do {
                userAddedReviews.push(userReview);
            };
        check userAddedReview.close();
        stream<DestinationsWithLocationCount, sql:Error?> destination_with_location_count_stream = self.connection->query(`SELECT d.id AS id, d.title AS destination_title,d.image AS destination_image,COUNT(dl.id) AS location_count FROM destinations d INNER JOIN destination_location dl ON d.id = dl.destinations_id GROUP BY d.id, d.title, d.image ORDER BY location_count DESC LIMIT 8`);
        DestinationsWithLocationCount[] destinations_with_location_count = [];
        check from DestinationsWithLocationCount destination in destination_with_location_count_stream
            do {
                destinations_with_location_count.push(destination);
            };
        check destination_with_location_count_stream.close();
        stream<userOffers, sql:Error?> user_offers_stream = self.connection->query(`SELECT offers.from_Date,offers.to_Date,offers.title AS offer_title,offers.image AS offer_image, destination_location.title AS destinations_name , country.name AS country FROM offers INNER JOIN destination_location ON destination_location.id = offers.destination_location_id INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON country.id = destinations.country_id WHERE offers.to_Date BETWEEN NOW() AND DATE_ADD(NOW(), INTERVAL 2 DAY) LIMIT 3`);
        userOffers[] offers = [];
        check from userOffers offer in user_offers_stream
            do {
                offers.push(offer);
            };
        int|sql:Error destination_count = check self.connection->queryRow(`SELECT COUNT(*) FROM destinations`);
        int|sql:Error users_count = check self.connection->queryRow(`SELECT COUNT(*) FROM user`);
        int|sql:Error destination_location_count = check self.connection->queryRow(`SELECT COUNT(*) FROM destination_location`);
        json bannerData = {
            destination_count: check destination_count,
            users_count: check users_count,
            destination_location_count: check destination_location_count
        };
        backendResponse.setJsonPayload({
            destinationLocation: QuickRouteDestination.toJson(),
            userSiteReviews: userAddedReviews.toJson(),
            destinations_with_location_count: destinations_with_location_count.toJson(),
            offers: offers.toJson(),
            bannerData: bannerData
        });
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function get locationReviews(string location_id) returns http:Response|error {
        http:Response backendResponse = new;
        stream<LocationReviewDetails, sql:Error?> dbLocationReview_strem = self.connection->query(`SELECT ratings.id AS rating_id, 
                   ratings.rating_count, 
                   ratings.review_img, 
                   ratings.review, 
                   user.first_name, 
                   user.last_name, 
                   user.email 
            FROM ratings 
            INNER JOIN user ON user.id = ratings.user_id 
            WHERE destination_location_id =${location_id}`);
        LocationReviewDetails[] LocationReviews = [];
        check from LocationReviewDetails dblocationReview in dbLocationReview_strem
            do {
                LocationReviews.push(dblocationReview);
            };
        check dbLocationReview_strem.close();
        backendResponse.setJsonPayload(LocationReviews.toJson());
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function get countries() returns http:Response|error {
        http:Response backendResponse = new;
        stream<DBCountry, sql:Error?> dbCountries_stream = self.connection->query(`SELECT * from country ORDER BY name ASC`);
        DBCountry[] countries = [];
        check from DBCountry country in dbCountries_stream
            do {
                countries.push(country);
            };
        check dbCountries_stream.close();
        backendResponse.setJsonPayload(countries.toJson());
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function get destinations() returns http:Response|error {
        http:Response backendResponse = new;
        stream<DBDestination, sql:Error?> dbDestinations_stream = self.connection->query(`SELECT * from destinations ORDER BY title ASC`);
        DBDestination[] destinationsArray = [];
        check from DBDestination destination in dbDestinations_stream
            do {
                destinationsArray.push(destination);
            };
        check dbDestinations_stream.close();
        backendResponse.setJsonPayload(destinationsArray.toJson());
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function get tourTypes() returns http:Response|error {
        http:Response backendResponse = new;
        stream<DBTourType, sql:Error?> tourTypes_stream = self.connection->query(`SELECT * from tour_type ORDER BY type ASC`);
        DBTourType[] tourTypesArray = [];
        check from DBTourType tourType in tourTypes_stream
            do {
                tourTypesArray.push(tourType);
            };
        check tourTypes_stream.close();
        backendResponse.setJsonPayload(tourTypesArray.toJson());
        backendResponse.statusCode = http:STATUS_OK;
        return backendResponse;
    }

    resource function post generateItinerary/[string BALUSERTOKEN](int trip_plan_id) returns http:Response|error {
        http:Response backendResponse = new;
        boolean|error requestFilterUser = filters:requestFilterUser(BALUSERTOKEN);

        if requestFilterUser is boolean && requestFilterUser == false {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_UNAUTHORIZED, "Token expired");
        }
        stream<locations, sql:Error?> location_stream = self.connection->query(`SELECT title FROM plan_has_des INNER JOIN destination_location ON destination_location.id = plan_has_des.destination_location_id WHERE trip_plan_id = ${trip_plan_id}`);
        locations[] locationsArray = [];
        check from locations location in location_stream
            do {
                locationsArray.push(location);
            };
        check location_stream.close();
        if (locationsArray.length() == 0) {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_NOT_FOUND, "No locations found");
        } else {
            string itineraryPrompt = "Generate two suggested travel itineraries based on the provided location names. Group locations that belong to the same destination. Ensure each itinerary is arranged in a cost-effective order, considering current conditions like weather, local events, and popular attractions. The itinerary should be structured by days, with each day's item including a title (a summary of the day), a description (a short summary of the activities for that day), and an estimated date. Consider reasonable travel times between countries (e.g., a full day of travel between Sri Lanka and Japan) and add buffer days if needed for flights or rest. Ensure that **all provided locations** are included in both itineraries. Return the result as a JSON object.Use this inputs as your parameters of destination locations.\n\nInputs:" + locationsArray.toString() + "Use only given inputs.if there is one location use that only.\n\nOutput format:\nThe output should be a JSON object structured as follows:\n{\"itineraries\": [{ \"itinerary\": [ { \"day\": \"Day 1\",\"title\": \"Exploring Paris\",\"description\": \"Visit the iconic Eiffel Tower and the world-renowned Louvre Museum.\" }, {\"day\": \"Day 2\", \"title\": \"Discovering Rome\", \"description\": \"Explore the ancient Colosseum and the magnificent Vatican City.\"}, { \"day\": \"Day 3\", \"title\": \"Adventuring in New York\", \"description\": \"Enjoy a visit to the Statue of Liberty and a stroll through Central Park.\" }]}, {\"itinerary\": [{\"day\": \"Day 1\", \"title\": \"A Day in the City of Lights\",  \"description\": \"Start with the Eiffel Tower, followed by the Louvre Museum.\"  }, { \"day\": \"Day 2\", \"title\": \"Ancient Wonders of Rome\", \"description\": \"Visit the Colosseum and the Vatican City.\" }, { \"day\": \"Day 3\", \"title\": \"New York Adventures\", \"description\": \"Explore Central Park and the Statue of Liberty.\"}]}]}";
            json|error result = OpenAI:generateText(itineraryPrompt);
            if (result is json) {
                json choicesArray = check result.choices;
                if (choicesArray is json[]) {
                    json firstChoice = choicesArray[0];
                    string content = (check firstChoice.message.content).toString();
                    json jsonResponse = check jsondata:parseString(content);
                    backendResponse.setJsonPayload(jsonResponse);
                    backendResponse.statusCode = http:STATUS_OK;
                } else {
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                }
            } else {
                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
            }
        }
        return backendResponse;
    }

    resource function get destination(int destinationId) returns error|http:Response {
        http:Response backendResponse = new;

        DBDestination|sql:Error queryRow = self.connection->queryRow(`SELECT * FROM destinations WHERE id=${destinationId}`);
        if queryRow is sql:Error {
            return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_INTERNAL_SERVER_ERROR, utils:DATABASE_ERROR);
        }

        stream<userOffers, sql:Error?> user_offers_stream = self.connection->query(`SELECT offers.from_Date,offers.to_Date,offers.title AS offer_title,offers.image AS offer_image, destination_location.title AS destinations_name , country.name AS country FROM offers INNER JOIN destination_location ON destination_location.id = offers.destination_location_id INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON country.id = destinations.country_id WHERE destinations.id=${destinationId} ORDER BY offers.to_Date DESC LIMIT 3`);
        userOffers[] offers = [];

        check from userOffers offer in user_offers_stream
            do {
                offers.push(offer);
            };

        stream<DBLocationDetailsWithRatings, sql:Error?> dbDestination_stream = self.connection->query(`SELECT destination_location.id AS location_id, destination_location.title AS title, destination_location.image AS image, destination_location.overview AS overview, tour_type.type AS tour_type, destinations.title AS destination_title, country.name AS country_name, COUNT(ratings.rating_count) AS total_ratings, ROUND(AVG(ratings.rating_count), 1) AS average_rating FROM destination_location INNER JOIN destinations ON destinations.id = destination_location.destinations_id INNER JOIN country ON destinations.country_id = country.id INNER JOIN tour_type ON destination_location.tour_type_id = tour_type.id LEFT JOIN ratings ON destination_location.id = ratings.destination_location_id WHERE destinations.id=${destinationId} GROUP BY destination_location.id, destination_location.title, destination_location.image, destination_location.overview, tour_type.type, destinations.title, country.name`);
        DBLocationDetailsWithRatings[] QuickRouteDestination = [];
        check from DBLocationDetailsWithRatings dbDestination in dbDestination_stream
            do {
                QuickRouteDestination.push(dbDestination);
            };
        check dbDestination_stream.close();

        json reponseObj = {
            destinationLocations: QuickRouteDestination.toJson(),
            offers: offers.toJson(),
            destination: queryRow.toJson()
        };
        return utils:returnResponseWithStatusCode(backendResponse, http:STATUS_OK, reponseObj, true);
    }

    isolated resource function get user/sendEmail/[string BALUSERTOKEN]() returns http:Response|error {
        json decodeJWT = check jwt:decodeJWT(BALUSERTOKEN);
        UserDTO payload = check jsondata:parseString(decodeJWT.toString());
        http:Response backendResponse = new;
        if (time:validateExpierTime(time:currentTimeStamp(), payload.expiryTime)) {
            DBUser|sql:Error result = self.connection->queryRow(`SELECT * FROM user WHERE email = (${payload.email})`);
            if result is sql:NoRowsError {
                backendResponse.setJsonPayload({success: false, message: "user not found"});
                backendResponse.statusCode = http:STATUS_NOT_FOUND;
                return backendResponse;
            } else if result is sql:Error {
                backendResponse.setJsonPayload({success: false, message: "database error"});
                backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                return backendResponse;
            } else {
                string emailTemplate = "./resources/templates/email.txt";
                string bodyContent = check io:fileReadString(emailTemplate);
                boolean sendEmail = email:sendEmail(subject = "Thank you for choosing QuickRoute AI Base Itinerary Planner", body = bodyContent, to = result.email);
                if sendEmail {
                    backendResponse.setJsonPayload({success: true, message: "email sent"});
                    backendResponse.statusCode = http:STATUS_OK;
                    return backendResponse;
                } else {
                    backendResponse.setJsonPayload({success: false, message: "email not sent"});
                    backendResponse.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
                    return backendResponse;
                }
            }
        } else {
            backendResponse.setJsonPayload({success: false, message: "token expired"});
            backendResponse.statusCode = http:STATUS_UNAUTHORIZED;
            return backendResponse;
        }
    }
}

